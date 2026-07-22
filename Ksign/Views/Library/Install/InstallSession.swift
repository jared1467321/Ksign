//
//  InstallSession.swift
//  Ksign
//

import SwiftUI
import Combine
import IDeviceSwift
import OSLog

// Owns every in-flight install for the whole app.
//
// This exists so the install drawer can be an overlay at the tab-bar root
// rather than a sheet on `LibraryView`. Sheets die when dismissed and can't
// be shown over another tab; a singleton holding the jobs means the drawer is
// just a *view* of state that lives somewhere else, so collapsing it, walking
// off to Settings, and dragging it back up costs nothing.
@MainActor
final class InstallSession: ObservableObject {
	static let shared = InstallSession()

	// Only jobs still worth showing. Completed ones are removed shortly after
	// they finish so the drawer shows what's *left*; failed ones stay put so
	// a failure doesn't quietly vanish.
	@Published private(set) var jobs: [InstallJob] = []

	@Published private(set) var completedCount = 0
	@Published private(set) var totalCount = 0
	@Published private(set) var aggregateProgress: Double = 0

	// Whether the drawer sheet is on screen. Dismissing it is now purely
	// cosmetic — the jobs live here, so nothing stops and nothing restarts
	// when it closes. That's what lets it be a plain sheet again.
	@Published var isDrawerPresented = false

	// Whether the queue is handing out slots. Mirrored onto the coordinator,
	// which is where it actually takes effect.
	@Published private(set) var isPaused = false

	// The Safari sheet for server method 1, hoisted up from the row.
	@Published var webviewJob: InstallJob?

	// Finished jobs are parked here briefly instead of being released
	// immediately: `ServerInstaller` shuts its Vapor server down in `deinit`,
	// and there's no reason to race iOS to the finish line.
	private var _retired: [InstallJob] = []
	private var _tickTask: Task<Void, Never>?

	// Batched-prompt coordination. Server + local installs park at `.ready` and
	// fire in groups of this size behind one confirmation each; other methods
	// leave this false and prompt per app. The size is read from Settings at the
	// start of each batch.
	private var _willBatch = false
	private var _batchGroupSize = 5

	// How many installs may be *building* at once — archiving the .ipa and
	// standing up its server. Deliberately a small fixed number and no longer
	// tied to the batch group size: a batched job releases its slot the instant
	// it's built and parks at the prompt, so a group of 100 assembles a few
	// builds at a time rather than archiving 100 IPAs and opening 100 servers
	// in one breath. This is the ceiling on concurrent *work*, not on how many
	// apps a single prompt can carry.
	private let _buildConcurrency = 3

	private init() {}

	var isActive: Bool { !jobs.isEmpty }

	// MARK: - Starting

	func start(apps: [AppInfoPresentable]) {
		guard !apps.isEmpty else { return }

		// Settle batching once per batch, at its start, so it can't change under
		// jobs already in flight. Server + local collapses each group of prompts
		// into one and runs the group concurrently; idevice and the external
		// server keep the default limit and prompt per app as before.
		if jobs.isEmpty {
			let method = UserDefaults.standard.integer(forKey: "Feather.installationMethod")
			let server = UserDefaults.standard.integer(forKey: "Feather.serverMethod")
			_willBatch = (method == 0 && server == 0)

			// Set in Settings › Installation. Absent reads as 0, so fall back to 5;
			// clamp to the range the stepper offers. 1 = one prompt per app.
			let stored = UserDefaults.standard.integer(forKey: "Feather.batchGroupSize")
			_batchGroupSize = stored == 0 ? 5 : min(100, max(1, stored))

			// No longer keyed to the group size. A batched job hands its slot
			// back as soon as it's parked at the prompt (see InstallJob's
			// `.awaiting` transition), so a group far larger than this can still
			// assemble — it just fills a few builds at a time. Keeping this small
			// is what makes a group size of 100 safe instead of a hundred-way
			// archive storm.
			//
			// Capped at the group size only so the smallest settings stay tidy:
			// at size 1 ("a prompt per app") this keeps building strictly
			// sequential, so prompts appear one at a time rather than three
			// racing each other. It can't wedge a larger group — parked jobs
			// free their slots, so the queue drains regardless of the cap.
			InstallQueueCoordinator.shared.setMaxConcurrent(
				_willBatch ? min(_buildConcurrency, _batchGroupSize) : _buildConcurrency
			)
		}

		for app in apps {
			// A failed row for this app would otherwise block re-installing it
			// entirely — `start` would see it as a duplicate and skip, so the
			// Install button would silently do nothing. Clear it out first.
			if let stale = jobs.firstIndex(where: { $0.app.uuid == app.uuid && $0.phase == .failed }) {
				jobs[stale].cancel()
				jobs.remove(at: stale)
				totalCount = max(0, totalCount - 1)
			}

			// Don't queue the same app twice if it's already going.
			if jobs.contains(where: { $0.app.uuid == app.uuid }) { continue }

			do {
				let job = try InstallJob(app: app)
				jobs.append(job)
				totalCount += 1
				job.start()
			} catch {
				Logger.misc.error("Couldn't start install for \(app.identifier ?? "?"): \(error.localizedDescription)")
			}
		}

		guard isActive else { return }

		// Claimed once for the whole batch rather than once per row. The rows
		// each used to start and stop this, which meant the *first* app to
		// finish stopped background audio for everything still installing.
		//
		// No local flag guards this any more: the manager tracks claims by
		// owner, so `start(apps:)` running again for apps added to a batch
		// already in flight is a no-op rather than a second claim to balance.
		BackgroundAudioManager.shared.claim(.bulkInstalls)

		isDrawerPresented = true
		_startTicking()
	}

	// MARK: - Finishing

	func jobDidFinish(_ job: InstallJob) {
		// A job leaving the running set (done or failed) can let a final partial
		// group fire — recompute before anything else.
		if _willBatch { _formBatchGroups() }

		guard job.phase == .completed else {
			// Failed jobs stay on screen — that's the only signal you get.
			return
		}

		completedCount += 1

		// Let the completion animation land before the row disappears.
		Task { @MainActor [weak self] in
			try? await Task.sleep(nanoseconds: 1_800_000_000)
			self?._retire(job)
		}
	}

	private func _retire(_ job: InstallJob) {
		guard let index = jobs.firstIndex(where: { $0 === job }) else { return }

		withAnimation(.easeInOut(duration: 0.25)) {
			_ = jobs.remove(at: index)
		}

		_retired.append(job)

		Task { @MainActor [weak self] in
			try? await Task.sleep(nanoseconds: 10_000_000_000)
			guard let self else { return }
			self._retired.removeAll { $0 === job }
		}

		_finishIfIdle()
	}

	// Drops a single job, from the row's context menu.
	//
	// `cancel()` first so the queue slot is handed back — without it a job
	// removed mid-flight holds its slot forever and everything behind it
	// stops, which is only visible as "the batch mysteriously stalled".
	func remove(_ job: InstallJob) {
		job.cancel()

		guard let index = jobs.firstIndex(where: { $0 === job }) else { return }

		withAnimation(.easeInOut(duration: 0.25)) {
			_ = jobs.remove(at: index)
		}

		// Keep the count honest: "4 of 7" with six rows showing is worse than
		// no count at all.
		totalCount = max(0, totalCount - 1)

		if webviewJob === job { webviewJob = nil }

		if _willBatch { _formBatchGroups() }
		_finishIfIdle()
	}

	func retry(_ job: InstallJob) {
		job.retry()

		// The bug this closes: retrying pulls the app out to its own solo prompt
		// (batchRole → none), which shrinks the pool the pending group was
		// counting on. `remove` already re-evaluated after changing that pool;
		// retry never did — so the apps left behind would sit waiting for a
		// group that could no longer fill, and the only way out was to start a
		// fresh batch. Re-running the grouping here means the remainder fires on
		// its own the moment nothing else is still coming, exactly as if the
		// retried app had been removed.
		if _willBatch { _formBatchGroups() }
	}

	func togglePause() {
		isPaused.toggle()
		InstallQueueCoordinator.shared.setPaused(isPaused)
	}

	// How many jobs are sitting in the queue rather than installing.
	var waitingCount: Int {
		jobs.filter { $0.phase == .queued }.count
	}

	// How many apps are actually being installed at this moment — the ones
	// holding a queue slot, not the ones lined up behind it.
	//
	// Recomputed rather than stored, and `phase` lives on the job rather than
	// here, so a queued job flipping to running doesn't republish this object
	// on its own. It doesn't need to: the 0.4s tick reassigns
	// `aggregateProgress` the whole time a batch is live, which redraws
	// anything reading this. Worst case the count is 0.4s stale.
	var runningCount: Int {
		jobs.filter { $0.phase == .running }.count
	}

	// How many rows are still on the drawer. Deliberately not `totalCount`:
	// completed apps are retired out of `jobs`, so this shrinks as the batch
	// goes, while `totalCount` stays fixed at the batch size because the
	// progress bar needs a denominator that doesn't move under it.
	var remainingCount: Int { jobs.count }

	// Clears everything, including failed rows. Backs the drawer's close button.
	func dismissAll() {
		for job in jobs { job.cancel() }
		withAnimation(.easeInOut(duration: 0.25)) { jobs.removeAll() }
		_finishIfIdle()
	}

	private func _finishIfIdle() {
		guard jobs.isEmpty else { return }

		BackgroundAudioManager.shared.release(.bulkInstalls)

		_stopTicking()
		webviewJob = nil

		// Don't let a pause outlive the batch that was paused — otherwise the
		// next install silently never starts.
		isPaused = false
		InstallQueueCoordinator.shared.setPaused(false)

		// Back to defaults so the next batch starts clean.
		_willBatch = false
		InstallQueueCoordinator.shared.setMaxConcurrent(_buildConcurrency)

		isDrawerPresented = false

		completedCount = 0
		totalCount = 0
		aggregateProgress = 0
	}

	// MARK: - Batched prompts

	// A job finished building and parked at `.ready` instead of prompting.
	func jobBecameReadyForBatch(_ job: InstallJob) {
		_formBatchGroups()
	}

	// The manifest for a prompt is assembled here, from scratch, every time
	// anything changes — a build finishing, a failure, a removal, a retry. It is
	// never a list decided in advance and held: it's whatever is genuinely ready
	// at this instant, so a retry or a drop can't leave it pointing at apps that
	// have moved on. That's what keeps it from drifting out of sync.
	private func _formBatchGroups() {
		guard _willBatch else { return }

		while true {
			// Built, parked at the prompt, and still live — the real candidates
			// for a manifest right now. Recomputed each pass so firing one group
			// (or anything else mutating `jobs`) is reflected before the next.
			let readyNow = jobs.filter {
				$0.batchRole == .awaiting && $0.phase != .failed && $0.phase != .completed
			}

			// Anything that could still join later: batching, not yet parked,
			// not finished. While even one exists, a partial group might still
			// grow, so we wait rather than fire short. Because a parked job now
			// releases its build slot, whatever is queued here is guaranteed to
			// get a chance to build — so this can't stay true forever and wedge
			// the remainder the way a stuck slot used to.
			let moreComing = jobs.contains {
				$0.batchRole == .pending && $0.phase != .failed && $0.phase != .completed
			}

			if readyNow.count >= _batchGroupSize {
				// A full manifest's worth is ready: take exactly the batch size,
				// fire it, and loop — a big backlog fires as several full groups.
				_fireBatchGroup(Array(readyNow.prefix(_batchGroupSize)))
			} else if !moreComing && !readyNow.isEmpty {
				// Nothing else is coming and the group is short (say 7 when the
				// size is 10): fire what's actually here instead of waiting on
				// apps that will never arrive.
				_fireBatchGroup(readyNow)
			} else {
				break
			}
		}
	}

	private func _fireBatchGroup(_ group: [InstallJob]) {
		guard let host = group.first else { return }
		let members = Array(group.dropFirst())

		// The host's manifest carries every member; each member's payload is
		// still served by its own server, so only the manifest is shared.
		host.becomeBatchHost(memberItems: members.compactMap { $0.ownManifestItem })
		for member in members { member.becomeBatchMember(host: host) }

		host.fireBatchedPrompt()
	}

	// MARK: - Aggregate progress

	// Sampled on a timer rather than republished from the jobs. The server
	// method's progress poller writes `installProgress` every millisecond; if
	// that were forwarded up to here it would redraw the entire drawer — and
	// whatever tab is behind it — a thousand times a second.
	private func _startTicking() {
		guard _tickTask == nil else { return }

		_tickTask = Task { @MainActor [weak self] in
			while !Task.isCancelled {
				self?._recomputeProgress()

				// While there are jobs, keep verifying that the keep-alive is
				// actually running rather than trusting the claim we made when
				// the batch started. An interruption — a call, an alarm,
				// another app taking the audio session — stops the engine and
				// it does not come back on its own; before this, the rest of
				// the batch simply ran unprotected and nothing said so.
				//
				// Idempotent and gated by its own backoff, so this is a cheap
				// check on the common path, not a restart attempt every 0.4s.
				BackgroundAudioManager.shared.ensureRunning()

				try? await Task.sleep(nanoseconds: 400_000_000) // 0.4s
				if self == nil { break }
			}
		}
	}

	private func _stopTicking() {
		_tickTask?.cancel()
		_tickTask = nil
	}

	private func _recomputeProgress() {
		guard totalCount > 0 else {
			aggregateProgress = 0
			return
		}

		// Jobs already retired count as a whole unit each; the ones still
		// running contribute whatever they've managed so far.
		let finished = Double(max(0, totalCount - jobs.count))
		let inFlight = jobs.reduce(0.0) { $0 + $1.viewModel.overallProgress }

		aggregateProgress = min(1.0, (finished + inFlight) / Double(totalCount))
	}

	// MARK: - Webview (server method 1)

	func presentWebview(for job: InstallJob) {
		// The webview is presented from inside the drawer, so the drawer has
		// to be up for it to appear at all.
		isDrawerPresented = true
		webviewJob = job
	}

	func dismissWebview(for job: InstallJob) {
		if webviewJob === job { webviewJob = nil }
	}
}

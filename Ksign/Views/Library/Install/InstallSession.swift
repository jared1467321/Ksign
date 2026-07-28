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

	// The drawer prints "\(completedCount) of \(totalCount) installed" off these
	// two, and has always got it right. The pill shows the same pair — but not
	// from a `didSet`, and not on every mutation of them. See `_reportTally`.
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

	// The server for the group currently installing. Held here so it outlives
	// the host's own row (which may finish and retire first) and keeps serving
	// the members' payloads; shut down once the whole group is done.
	private var _activeHostInstaller: ServerInstaller?

	// How many apps archive at once while batching. Fixed and deliberately
	// small: building is the rationed part; the manifest can hold far more apps
	// than this, they just build a few at a time.
	private let _batchBuildConcurrency = 5

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
			// Cleared here rather than at the end of the last batch. Zeroing
			// these on finish would fire `didSet` and wipe the final "12 of 12"
			// the moment it landed — the pill lingers for a few seconds after
			// the last release and that tally is what it shows.
			completedCount = 0
			totalCount = 0
			aggregateProgress = 0

			let method = UserDefaults.standard.integer(forKey: "Feather.installationMethod")
			let server = UserDefaults.standard.integer(forKey: "Feather.serverMethod")
			_willBatch = (method == 0 && server == 0)

			// Set in Settings › Installation. Absent reads as 0, so fall back to 5;
			// clamp to the range the stepper offers. 1 = one prompt per app.
			let stored = UserDefaults.standard.integer(forKey: "Feather.batchGroupSize")
			_batchGroupSize = stored == 0 ? 5 : min(100, max(1, stored))

			// Build concurrency is fixed and independent of the manifest size. Only
			// a few apps archive at once; each then parks (handing its slot back)
			// while the pool fills, so a 100-app manifest is still built a few at a
			// time — and a stuck install can't wedge the queue, because it isn't
			// holding a slot.
			InstallQueueCoordinator.shared.setMaxConcurrent(_willBatch ? _batchBuildConcurrency : 3)
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
				// Batched jobs are released to build a group at a time (see
				// `_admitBatchJobs`), so only a manifest's worth of servers is ever
				// alive at once. Non-batched installs start right away.
				if !_willBatch { job.start() }
			} catch {
				Logger.misc.error("Couldn't start install for \(app.identifier ?? "?"): \(error.localizedDescription)")
			}
		}

		if _willBatch { _admitBatchJobs() }

		guard isActive else { return }

		// Claimed once for the whole batch rather than once per row. The rows
		// each used to start and stop this, which meant the *first* app to
		// finish stopped background audio for everything still installing.
		//
		// No local flag guards this any more: the manager tracks claims by
		// owner, so `start(apps:)` running again for apps added to a batch
		// already in flight is a no-op rather than a second claim to balance.
		BackgroundAudioManager.shared.claim(.bulkInstalls)

		// One seed, after the whole batch is admitted, so the denominator is
		// final. Previously every `totalCount += 1` pushed its own update, so a
		// five-app batch opened with seven of them before a single app moved.
		_reportTally()

		isDrawerPresented = true
		_startTicking()
	}

	// MARK: - Finishing

	func jobDidFinish(_ job: InstallJob) {
		if _willBatch {
			// Once every app in the current group is done, its shared server can
			// shut down — before the next group brings its own up.
			if !_hasGroupInFlight {
				_activeHostInstaller?.shutDown()
				_activeHostInstaller = nil
			}
			// A finished job frees room in the active window: release the next
			// batched apps to build, then re-evaluate groups.
			_admitBatchJobs()
			_formBatchGroups()
		}

		guard job.phase == .completed else {
			// Failed jobs stay on screen — that's the only signal you get.
			_releaseIfNothingRunning()
			return
		}

		completedCount += 1

		// The one call per app. An app installed, the number moved, say so.
		_reportTally()

		_releaseIfNothingRunning()

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
		_reportTally()

		if webviewJob === job { webviewJob = nil }

		if _willBatch {
			_admitBatchJobs()
			_formBatchGroups()
		}
		_finishIfIdle()
	}

	func retry(_ job: InstallJob) {
		guard _willBatch else {
			// idevice / external server: re-prompt just this app.
			job.retry()
			return
		}

		// Dynamic regroup. Return the tapped app and every other app still stuck
		// at a shared prompt (dismissed, or skipped by iOS) to the ready pool,
		// then reform fresh manifests from them plus anything else waiting or
		// still building. Dismiss a group with nothing processed and retrying
		// re-prompts the whole manifest; lose half a group and it regroups the
		// stragglers with the next apps in line.
		var returned = false
		for candidate in jobs where candidate === job || candidate.isStuckAtPrompt {
			candidate.rejoinPool()
			returned = true
		}
		if returned { _formBatchGroups() }
	}

	func togglePause() {
		isPaused.toggle()
		InstallQueueCoordinator.shared.setPaused(isPaused)
		// Resuming builds the next manifest from whatever's in the ready pool.
		if !isPaused, _willBatch {
			_admitBatchJobs()
			_formBatchGroups()
		}
	}

	// Called from the drawer while paused. Sends every app still tied to the
	// current manifest — stuck at the prompt, or stuck partway through installing
	// and never reported back — to the ready pool. Apps already waiting, queued,
	// or finished are left alone. Nothing fires until resume, which rebuilds the
	// manifest from whatever's in the pool.
	func clearStuckManifest() {
		guard _willBatch else { return }
		_activeHostInstaller?.shutDown()
		_activeHostInstaller = nil
		for job in jobs where job.isInFlightGroupMember {
			job.rejoinPool()
		}
	}

	// Whether there's a manifest in flight the paused "clear" action could
	// reset — any app still at a prompt or stuck mid-install.
	var hasInFlightGroup: Bool {
		jobs.contains { $0.isInFlightGroupMember }
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

	// The only thing the pill is ever told, and the only place it's told it.
	//
	// iOS budgets how often an app may update a Live Activity, and the widget is
	// drawn out of process so there is no local redraw to fall back on when that
	// budget runs out — updates are simply not delivered, silently, and the pill
	// sits on whatever it last received. The drawer has no such limit, which is
	// why it can be redrawn sixty times a second and the pill cannot.
	//
	// So this is called on the three events that genuinely move the number: the
	// batch starting, an app finishing, a row being dropped. Nothing else. The
	// per-phase reporting that used to sit in `InstallJob._handleStatus` spent
	// four or five updates per app on text — Packaging, Ready, Sending Manifest,
	// Sending Payload, Installing — and that text was inferred from
	// `jobs.first(where: running)`, so with several jobs in flight it named a
	// different app each time and was wrong as often as not. A five-app batch
	// made seventeen update requests; it needs six.
	private func _reportTally() {
		guard #available(iOS 16.2, *) else { return }

		KeepAliveActivityController.shared.report(
			.bulkInstalls,
			completed: completedCount,
			total: totalCount
		)
	}

	// Everything is settled but failed rows stay on screen, so `jobs` never
	// empties and `_finishIfIdle` never runs. That's the same condition the
	// drawer already tests to decide it's finished-with-failures.
	//
	// Without this a single failed install meant `release(.bulkInstalls)` was
	// never called and the silent audio ran until the app was killed.
	private func _releaseIfNothingRunning() {
		guard !jobs.isEmpty, jobs.allSatisfy({ $0.phase == .completed || $0.phase == .failed }) else { return }

		BackgroundAudioManager.shared.release(.bulkInstalls)
		_stopTicking()
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
		_activeHostInstaller?.shutDown()
		_activeHostInstaller = nil
		InstallQueueCoordinator.shared.setMaxConcurrent(3)

		isDrawerPresented = false

		// No final tally to send: the last app's completion already sent it, and
		// the counters deliberately keep their finished figures so "5 of 5" is
		// what the pill shows while the keep-alive winds down.
		//
		// Withdrawn once the linger is over, though. Nothing else ever clears this
		// owner's report, so left alone a finished tally outlives the batch and
		// the next thing to share the pill inherits it.
		if #available(iOS 16.2, *) {
			Task { @MainActor [weak self] in
				try? await Task.sleep(nanoseconds: 6_000_000_000)
				guard let self, self.jobs.isEmpty else { return }
				KeepAliveActivityController.shared.clearReport(.bulkInstalls)
			}
		}
	}

	// MARK: - Batched prompts

	// A job finished building and parked at `.ready` instead of prompting.
	func jobBecameReadyForBatch(_ job: InstallJob) {
		_formBatchGroups()
	}

	// Batched jobs are let go to build a group's worth at a time. Only this many
	// apps are ever building, parked, or installing at once, so at most a single
	// manifest's worth of servers is alive — archiving all of them up front is
	// what pinned the device. As apps finish, the next ones are released.
	private func _admitBatchJobs() {
		guard _willBatch else { return }
		while _admittedActiveCount < _batchGroupSize,
			  let next = jobs.first(where: { !$0.hasStarted }) {
			next.start()
		}
	}

	// Started (released to build) and not yet finished — building, parked at a
	// prompt, or installing. This is the count the admission window holds down.
	private var _admittedActiveCount: Int {
		jobs.filter { $0.hasStarted && $0.phase != .completed && $0.phase != .failed }.count
	}

	private func _formBatchGroups() {
		guard _willBatch else { return }
		// Paused: hold everything in the pool — resume is what fires the next
		// manifest.
		guard !isPaused else { return }

		// One group installs at a time. Firing the next manifest while the last
		// is still installing stacks prompt on top of prompt — so wait until the
		// current group has finished before assembling the next one.
		guard !_hasGroupInFlight else { return }

		let awaiting = jobs.filter {
			$0.batchRole == .awaiting && $0.phase != .failed && $0.phase != .completed
		}
		// Could anything still join a group? A queued or still-building
		// (pending) job might yet reach `.ready`.
		let moreComing = jobs.contains {
			$0.batchRole == .pending && $0.phase != .failed && $0.phase != .completed
		}

		if awaiting.count >= _batchGroupSize {
			_fireBatchGroup(Array(awaiting.prefix(_batchGroupSize)))
		} else if !moreComing && !awaiting.isEmpty {
			// Nothing more is coming — fire the remainder rather than waiting
			// for a full group that will never fill.
			_fireBatchGroup(awaiting)
		}
	}

	// A group is mid-install: at least one host/member has fired but isn't done
	// yet. While that holds, no new manifest fires, so prompts never stack up.
	// When the last member of the current group finishes, `jobDidFinish` calls
	// back in here and the next group goes.
	private var _hasGroupInFlight: Bool {
		jobs.contains {
			($0.batchRole == .host || $0.batchRole == .member)
				&& $0.phase != .completed && $0.phase != .failed
		}
	}

	private func _fireBatchGroup(_ group: [InstallJob]) {
		guard let host = group.first else { return }
		let members = Array(group.dropFirst())

		// One server for the whole group: the host serves its own payload and
		// every member's, keyed by app id. Members never stand up a server.
		host.becomeBatchHost(memberInstallers: members.compactMap { $0.installer })
		for member in members { member.becomeBatchMember(host: host) }

		// Keep the host's server alive until the group is done, even if the host's
		// own row finishes first — it's still serving the members.
		_activeHostInstaller = host.installer

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

				// Nothing here for the pill. This tick redraws the drawer, which
				// is on screen and can take 2.5 redraws a second; the pill is
				// drawn out of process by the system and cannot. It's fed from
				// `completedCount`/`totalCount`'s own `didSet` instead.

				try? await Task.sleep(nanoseconds: 400_000_000) // 0.4s
				if self == nil { break }
			}
		}
	}

	private func _stopTicking() {
		_tickTask?.cancel()
		_tickTask = nil

		// Deliberately does *not* withdraw the Dynamic Island counts. This runs
		// the instant the last row retires, so clearing here meant the pill
		// jumped from "11 of 12" straight to no bar and you never saw the batch
		// land. `_finishIfIdle` publishes the final tally instead, and the
		// controller drops it when the activity itself ends.
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

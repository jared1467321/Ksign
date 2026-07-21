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

	private init() {}

	var isActive: Bool { !jobs.isEmpty }

	// MARK: - Starting

	func start(apps: [AppInfoPresentable]) {
		guard !apps.isEmpty else { return }

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

		// Started once for the whole batch rather than once per row. The rows
		// each used to start and stop this, which meant the *first* app to
		// finish stopped background audio for everything still installing.
		BackgroundAudioManager.shared.start()

		isDrawerPresented = true
		_startTicking()
	}

	// MARK: - Finishing

	func jobDidFinish(_ job: InstallJob) {
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

		_finishIfIdle()
	}

	func retry(_ job: InstallJob) {
		job.retry()
	}

	func togglePause() {
		isPaused.toggle()
		InstallQueueCoordinator.shared.setPaused(isPaused)
	}

	// How many jobs are sitting in the queue rather than installing.
	var waitingCount: Int {
		jobs.filter { $0.phase == .queued }.count
	}

	// Clears everything, including failed rows. Backs the drawer's close button.
	func dismissAll() {
		for job in jobs { job.cancel() }
		withAnimation(.easeInOut(duration: 0.25)) { jobs.removeAll() }
		_finishIfIdle()
	}

	private func _finishIfIdle() {
		guard jobs.isEmpty else { return }

		BackgroundAudioManager.shared.stop()
		_stopTicking()
		webviewJob = nil

		// Don't let a pause outlive the batch that was paused — otherwise the
		// next install silently never starts.
		isPaused = false
		InstallQueueCoordinator.shared.setPaused(false)

		isDrawerPresented = false

		completedCount = 0
		totalCount = 0
		aggregateProgress = 0
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

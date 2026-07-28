//
//  KeepAliveTaskManager.swift
//  Ksign
//

import BackgroundTasks
import Foundation
import OSLog

// Puts the silent-audio keep-alive in the Dynamic Island while the app is
// backgrounded, the same way a download already gets a pill of its own.
//
// This is the *system* Live Activity that `BGContinuedProcessingTask` vends —
// the same mechanism `BackgroundTaskManager` uses for downloads — not
// ActivityKit. That matters: there is no widget extension, no new build
// target, and no pbxproj surgery. The cost is that the presentation belongs to
// iOS. We supply a title, a subtitle and a progress figure; we do not get to
// style it, and we do not get a tap target, so this is display-only. The badge
// at the top of the window stays the way in to the log.
//
// The pill is deliberately tied to *claims*, not to `isRunning`:
//
//   - Something claimed, engine up      → "Silent audio on"
//   - Something claimed, engine not up  → "Silent audio off — retrying"
//   - Nothing claimed                   → no pill at all
//
// The second case is the one worth leaving the app for. `isRunning` false while
// work is in flight is precisely the state where installs quietly die once the
// screen locks, and it is the state the old speaker badge existed to surface.
// A pill that only appeared when things were healthy would go missing exactly
// when it was needed.
//
// Nothing here runs below iOS 26, which is where `BGContinuedProcessingTask`
// starts. On earlier systems the badge is still the only indicator, unchanged.
@available(iOS 26.0, *)
final class KeepAliveTaskManager {
	static let shared = KeepAliveTaskManager()

	// Has to sit under the `BGTaskSchedulerPermittedIdentifiers` wildcard
	// already in Info.plist — `$(PRODUCT_BUNDLE_IDENTIFIER).userTask.*` — or
	// `submit` throws `notPermitted`. Same base as the download tasks, so the
	// two share one entry.
	private let _identifier = "\(Bundle.main.bundleIdentifier!).userTask.keepalive"

	// `sync` arrives on main (it's called from `BackgroundAudioStatus`, which
	// hops there), but BGTaskScheduler invokes the launch and expiration
	// handlers on its own queue. Same reasoning — and same shape — as
	// `BackgroundTaskManager`: every touch of this state goes through the lock,
	// and the lock is never held across a BackgroundTasks call.
	private let _lock = NSLock()

	private var _registered = false
	private var _task: BGContinuedProcessingTask?

	// A request is outstanding: submitted, but the launch handler hasn't run
	// yet. Without this the 0.4s install tick would submit dozens of duplicate
	// requests before the first one came back.
	private var _submitted = false

	// What the pill should currently say. Held so the launch handler can apply
	// it if the state moved on between submitting and starting.
	private var _wanted = false
	private var _title = ""
	private var _subtitle = ""

	// nil means indeterminate. Most owners — signing, import, extraction —
	// have no single number to report, so the ring only fills in for the ones
	// that do (see `report(progress:)`).
	private var _progress: Double?

	// Set when the person hits stop on the pill. Tapping stop should dismiss
	// the indicator, not kill the install it was reporting on, and it must not
	// come straight back on the next tick — so we stay quiet until everything
	// has been released and a genuinely new batch starts.
	private var _dismissed = false

	// `submit` can fail for reasons that won't clear immediately (the app is
	// already backgrounded, the system is at its task ceiling). Retrying every
	// 0.4s would be pointless noise.
	private var _nextAttempt = Date.distantPast
	private static let _retryDelay: TimeInterval = 5

	private init() { }

	// MARK: - Driven by BackgroundAudioStatus

	// Called on main every time the keep-alive republishes, which is often —
	// every evaluate during an install. Everything below is a no-op unless
	// something actually changed.
	func sync(isRunning: Bool, owners: [String]) {
		// Turning the feature off in Settings should take the pill with it,
		// rather than leaving one that reads "off — retrying" forever.
		let enabled = OptionsManager.shared.options.backgroundAudio
		let wanted = enabled && !owners.isEmpty

		let title = owners.isEmpty
			? "Keep-alive"
			: owners.joined(separator: ", ")

		let subtitle = isRunning
			? "Silent audio on"
			: "Silent audio off — retrying"

		_lock.lock()

		// A new set of owners is a new piece of work, so any progress figure
		// left over from the last one is meaningless.
		let ownersChanged = (_title != title)
		if ownersChanged { _progress = nil }

		let wasWanted = _wanted
		_wanted = wanted
		_title = title
		_subtitle = subtitle

		// Everything let go: clear the stop-button suppression so the next
		// batch gets a pill again.
		if !wanted { _dismissed = false }

		let dismissed = _dismissed
		let task = _task
		let submitted = _submitted
		let canAttempt = Date() >= _nextAttempt

		_lock.unlock()

		if wanted {
			// Dismissed by hand and the batch is still going: stay out of the
			// way entirely until everything is released.
			guard !dismissed else { return }

			if let task {
				_apply(to: task, title: title, subtitle: subtitle)
			} else if !submitted, canAttempt {
				_submit(title: title, subtitle: subtitle)
			}
			return
		}

		// Not wanted any more — finish the pill so it collapses with the
		// checkmark rather than being yanked off screen.
		if wasWanted || task != nil {
			_finish(success: true)
		}
	}

	// Optional, and only meaningful for owners that know how far along they
	// are. `InstallSession` already ticks every 0.4s for its own aggregate
	// progress and calls this from there; everything else leaves the ring
	// indeterminate, which is honest — a bar that never moves reads as broken.
	func report(progress: Double?) {
		_lock.lock()
		let changed = _progress != progress
		if changed { _progress = progress }
		let task = _task
		_lock.unlock()

		guard changed, let task else { return }
		_applyProgress(to: task, progress: progress)
	}

	// MARK: - Task lifecycle

	private func _submit(title: String, subtitle: String) {
		_registerIfNeeded()

		let request = BGContinuedProcessingTaskRequest(
			identifier: _identifier,
			title: title,
			subtitle: subtitle
		)

		// `.queue` rather than `.fail`: during a download-then-import chain the
		// download's own task may still hold the slot, and a keep-alive pill
		// that shows up a moment late is worth more than one that never shows
		// up at all.
		request.strategy = .queue

		_lock.lock()
		_submitted = true
		_lock.unlock()

		do {
			try BGTaskScheduler.shared.submit(request)
		} catch {
			_lock.lock()
			_submitted = false
			_nextAttempt = Date().addingTimeInterval(Self._retryDelay)
			_lock.unlock()

			// Expected rather than exceptional: submitting from the background
			// is not allowed, and the work that claimed the keep-alive carries
			// on regardless. Worth a line, not worth surfacing.
			Logger.misc.info("Keep-alive task not submitted: \(error.localizedDescription)")
		}
	}

	private func _registerIfNeeded() {
		_lock.lock()
		let already = _registered
		if !already { _registered = true }
		_lock.unlock()

		guard !already else { return }

		// Registering after launch is fine here — BGContinuedProcessingTask is
		// exempt from the usual "register before didFinishLaunching" rule.
		BGTaskScheduler.shared.register(forTaskWithIdentifier: _identifier, using: nil) { [weak self] task in
			guard
				let self,
				let task = task as? BGContinuedProcessingTask
			else {
				return
			}

			task.expirationHandler = { [weak self] in
				// Reached both when the person hits stop and when the system
				// reclaims the slot. Either way: drop the indicator, leave the
				// signing or installing entirely alone, and don't resubmit
				// until this batch is over.
				self?._handleExpiration()
			}

			self._lock.lock()
			self._task = task
			self._submitted = false
			let wanted = self._wanted && !self._dismissed
			let title = self._title
			let subtitle = self._subtitle
			let progress = self._progress
			self._lock.unlock()

			// The batch can finish between submitting and starting; if it did,
			// close the task immediately rather than leaving a stale pill.
			guard wanted else {
				self._finish(success: true)
				return
			}

			self._apply(to: task, title: title, subtitle: subtitle)
			self._applyProgress(to: task, progress: progress)
		}
	}

	private func _handleExpiration() {
		_lock.lock()
		_dismissed = true
		let task = _task
		_task = nil
		_submitted = false
		_appliedTitle = nil
		_appliedSubtitle = nil
		_lock.unlock()

		task?.setTaskCompleted(success: false)
	}

	private func _finish(success: Bool) {
		_lock.lock()
		let task = _task
		_task = nil
		_submitted = false
		_progress = nil
		_appliedTitle = nil
		_appliedSubtitle = nil
		_lock.unlock()

		// Whoever takes the task completes it; a second caller gets nil and
		// does nothing, so `setTaskCompleted` can't be called twice.
		task?.setTaskCompleted(success: success)
	}

	// MARK: - Applying state

	// What was last handed to the system. Tracked here rather than read back
	// off the task so this doesn't depend on those properties being readable,
	// and so the 0.4s tick doesn't call into BackgroundTasks with a string it
	// already sent.
	private var _appliedTitle: String?
	private var _appliedSubtitle: String?

	private func _apply(to task: BGContinuedProcessingTask, title: String, subtitle: String) {
		_lock.lock()
		let changed = _appliedTitle != title || _appliedSubtitle != subtitle
		if changed {
			_appliedTitle = title
			_appliedSubtitle = subtitle
		}
		_lock.unlock()

		guard changed else { return }
		task.updateTitle(title, subtitle: subtitle)
	}

	private func _applyProgress(to task: BGContinuedProcessingTask, progress: Double?) {
		guard let progress else {
			// An NSProgress with nothing on either side is indeterminate,
			// which is what we want for work that can't report a fraction.
			task.progress.totalUnitCount = 0
			task.progress.completedUnitCount = 0
			return
		}

		task.progress.totalUnitCount = 100
		task.progress.completedUnitCount = Int64(max(0, min(1, progress)) * 100)
	}
}

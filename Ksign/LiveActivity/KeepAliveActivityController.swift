//
//  KeepAliveActivityController.swift
//  Ksign
//

import ActivityKit
import Foundation
import OSLog

// Starts, updates and ends the keep-alive Live Activity.
//
// Why this rather than `BGContinuedProcessingTask`, which is what the download
// pill uses: that API is for finite work with a measurable percentage, and the
// system is entitled to reclaim a task that never progresses. A keep-alive
// indicator has no percentage and no finish line — it is a status display, the
// same shape as a weather or a sports activity. ActivityKit is the API for
// that shape.
//
// It also sidesteps the thing that most likely stopped the previous attempt
// working at all. A continued-processing task exists to buy an app background
// runtime; with the `audio` background mode already keeping this app awake
// there may be nothing for the system to grant, and it appears not to bother
// starting one. A Live Activity is drawn by the system from the widget
// extension and doesn't depend on the app being granted anything, so the
// silent audio can't suppress the very indicator that reports on it.
//
// Main-queue-confined by convention rather than by `@MainActor`, the same way
// `ExtractManager` handles its list: every caller already arrives inside
// `BackgroundAudioStatus`'s hop to main, and an actor annotation here would
// force isolation hops on a Swift 5 language-mode target for no benefit. The
// activity handle never leaves this queue.
@available(iOS 16.2, *)
final class KeepAliveActivityController {
	static let shared = KeepAliveActivityController()

	private var _activity: Activity<KeepAliveAttributes>?

	// The last state actually pushed. `sync` is called several times a second
	// during an install; without this every one of those would be an update
	// request for content identical to what's already on screen.
	private var _lastState: KeepAliveAttributes.ContentState?

	// The last owners that were actually holding something.
	//
	// Bulk signing calls `begin(.signing)` for app N and `end(.signing)` before
	// taking the next one, so between every app in the batch the owner list is
	// empty for a moment. Reading that literally meant ending the activity and
	// requesting a fresh one per app — the pill visibly tearing down and
	// rebuilding thirty times.
	//
	// `BackgroundAudioManager` already has this exact problem and already
	// solved it: its `_linger` keeps the engine running across those gaps
	// rather than rebuilding the audio session per app. This is the display
	// half of the same idea — during a gap the pill keeps saying what it said
	// before, because the keep-alive genuinely hasn't gone anywhere.
	private var _lastOwners: [String] = []

	// Batch position per owner, for the ones that count apps. Keyed by owner so
	// two things running at once can't overwrite each other's numbers — the
	// install tick fires several times a second and would otherwise flatten
	// whatever the signer had just reported.
	private var _counts: [String: (completed: Int, total: Int)] = [:]

	// A failed `request` usually means Live Activities are switched off for the
	// app, which won't change mid-batch. Retrying at 2Hz would be pointless.
	private var _nextAttempt = Date.distantPast
	private static let _retryDelay: TimeInterval = 30

	private init() { }

	// MARK: - Driven by BackgroundAudioStatus

	func sync(isRunning: Bool, owners: [String]) {
		// Gate on the setting, so switching background audio off in Settings ›
		// Features takes the pill with it rather than leaving one that reads
		// "off" forever.
		let enabled = OptionsManager.shared.options.backgroundAudio

		// Keyed on the engine actually running, not just on something being
		// claimed. That's what carries the pill through the linger window
		// between one signed app and the next, and it's also the more honest
		// reading of the feature: the pill is up exactly while the silent audio
		// is up. The `!owners.isEmpty` half keeps it visible in the case worth
		// seeing — something claimed, engine failed to start.
		let wanted = enabled && (isRunning || !owners.isEmpty)

		guard wanted else {
			_end()
			return
		}

		if !owners.isEmpty { _lastOwners = owners }

		// Mid-gap, keep showing whoever had it a moment ago rather than
		// flickering to "winding down" between every app in a batch.
		let display = owners.isEmpty ? _lastOwners : owners

		// Counts belong to whichever owner is actually being shown. If several
		// things hold the keep-alive at once the pill names the first, so the
		// bar has to follow the same one or the number and the name disagree.
		let counts = display.first.flatMap { _counts[$0] }

		let state = KeepAliveAttributes.ContentState(
			isRunning: isRunning,
			owners: display,
			completed: counts?.completed,
			total: counts?.total
		)

		guard let activity = _activity else {
			_start(with: state)
			return
		}

		// Nothing to say — don't spend a system update on it.
		guard state != _lastState else { return }
		_lastState = state

		Task {
			await activity.update(ActivityContent(state: state, staleDate: nil))
		}
	}

	// Called by whatever is doing the work. Pass nil for `total` when a batch
	// finishes, so a stale "12 of 12" can't sit under the next owner's name.
	//
	// Cheap to call on a timer: the state comparison in `sync` drops anything
	// that hasn't actually changed before it reaches the system.
	func report(_ owner: BackgroundAudioManager.Owner, completed: Int, total: Int?) {
		let key = owner.displayName

		if let total, total > 0 {
			_counts[key] = (completed: completed, total: total)
		} else {
			_counts.removeValue(forKey: key)
		}
	}

	// MARK: - Lifecycle

	private func _start(with state: KeepAliveAttributes.ContentState) {
		guard Date() >= _nextAttempt else { return }

		// Switched off for this app in Settings › Face ID or the app's own
		// notification settings. Nothing to be done about it from here, but
		// it's the single most likely reason for no pill appearing.
		guard ActivityAuthorizationInfo().areActivitiesEnabled else {
			_nextAttempt = Date().addingTimeInterval(Self._retryDelay)
			Logger.misc.error("Live Activities are disabled for this app — keep-alive pill can't be shown.")
			BackgroundAudioStatus.shared.record(.island, "can't show — Live Activities are turned off for ASign")
			return
		}

		do {
			_activity = try Activity.request(
				attributes: KeepAliveAttributes(startedAt: Date()),
				content: ActivityContent(state: state, staleDate: nil),
				// Everything is driven from inside the app. No server, so no
				// push token and no notification permission needed.
				pushType: nil
			)

			_lastState = state
			_nextAttempt = .distantPast

			BackgroundAudioStatus.shared.record(.island, "showing — \(state.summary)")
		} catch {
			_nextAttempt = Date().addingTimeInterval(Self._retryDelay)

			Logger.misc.error("Keep-alive Live Activity failed to start: \(error.localizedDescription)")
			BackgroundAudioStatus.shared.record(.island, "failed to start — \(error.localizedDescription)")
		}
	}

	private func _end() {
		guard let activity = _activity else { return }

		_activity = nil
		_lastState = nil
		_lastOwners = []
		_counts.removeAll()

		BackgroundAudioStatus.shared.record(.island, "dismissed — nothing left holding the keep-alive")

		Task {
			// `.immediate` rather than letting it linger on the Lock Screen.
			// The keep-alive is over the moment the last claim goes; a pill
			// that hangs around afterwards would be saying something untrue.
			await activity.end(nil, dismissalPolicy: .immediate)
		}
	}
}

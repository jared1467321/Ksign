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
	// What each owner has told us about itself. Fields are merged rather than
	// replaced, so the bulk signer can own the app count while `FR` owns the
	// phase text and neither wipes the other.
	private struct _Report: Equatable {
		var completed: Int?
		var total: Int?
		var fraction: Double?
		var detail: String?
	}

	private var _reports: [String: _Report] = [:]

	// When each owner last said something, as a monotonic counter rather than a
	// `Date` — deliberately *outside* `_Report` so it can't take part in the
	// equality check that decides whether anything actually changed.
	//
	// This is what replaces `display.first`. Owners arrive from
	// `BackgroundAudioManager` sorted alphabetically, which is a fine order for
	// a log line and a terrible one for choosing whose numbers to show: it puts
	// "Bulk export", "Downloads" and "Extraction" ahead of "Signing" every
	// time, so a single download in flight was enough to blank the signing
	// count — the first owner had no report at all and the bar simply vanished.
	private var _sequence: UInt64 = 0
	private var _reportSeq: [String: UInt64] = [:]

	// Whose numbers the pill is currently showing. Held on to rather than
	// recomputed every time so the bar doesn't ping-pong between two owners
	// that are both reporting — it stays with one until that one stops holding
	// the keep-alive or withdraws its figures.
	private var _focusOwner: String?

	// The most recent values handed to `sync`. Counts arrive on a completely
	// different schedule from keep-alive publishes — an app finishing importing
	// doesn't make the audio manager re-evaluate — so `report` needs to be able
	// to rebuild and push the state by itself. Without these it could only
	// write the number down and hope something else came along to send it,
	// which is why the numbers froze once the app was backgrounded and
	// evaluates got sparse.
	private var _lastIsRunning = false
	private var _lastOwnersInput: [String] = []

	// A failed `request` usually means Live Activities are switched off for the
	// app, which won't change mid-batch. Retrying at 2Hz would be pointless.
	private var _nextAttempt = Date.distantPast
	private static let _retryDelay: TimeInterval = 30

	private init() { }

	// MARK: - Queue confinement

	// Everything below touches `_reports`, `_activity` and the last-state cache,
	// and callers do not all arrive on the same thread: `BackgroundAudioStatus`
	// hops to main, `FR` wraps its stage reports in `MainActor.run`, but the
	// bulk signer's `Task` is only main-actor-isolated if SwiftUI's `View`
	// conformance happens to infer it — which is not something to bet a
	// dictionary's integrity on in a Swift 5 language-mode target.
	//
	// Inline when already on main so existing ordering is untouched, hopped
	// otherwise. `DispatchQueue.main.async` rather than a `Task`, for the same
	// FIFO reason `BackgroundAudioStatus` gives.
	private func _onMain(_ work: @escaping () -> Void) {
		if Thread.isMainThread {
			work()
		} else {
			DispatchQueue.main.async(execute: work)
		}
	}

	// MARK: - Driven by BackgroundAudioStatus

	func sync(isRunning: Bool, owners: [String]) {
		_onMain {
			self._lastIsRunning = isRunning
			self._lastOwnersInput = owners
			self._apply(isRunning: isRunning, owners: owners)
		}
	}

	// Sticky, then most-recent. Sticky first because two owners reporting at
	// once — a sign batch and the installs it hands off to, say — would
	// otherwise swap the bar's denominator back and forth under a name that
	// changes with it.
	private func _focusedOwner(among display: [String]) -> String? {
		if let current = _focusOwner,
		   display.contains(current),
		   _reports[current] != nil {
			return current
		}

		var best: String?
		var bestSeq: UInt64 = 0

		for owner in display where _reports[owner] != nil {
			let seq = _reportSeq[owner] ?? 0
			if best == nil || seq > bestSeq {
				best = owner
				bestSeq = seq
			}
		}

		return best
	}

	private func _apply(isRunning: Bool, owners: [String]) {
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

		// Whose numbers to show. Not `display.first` — see `_reportSeq`. Stay
		// with the owner already in focus while it's still holding the
		// keep-alive and still has something to say; otherwise hand focus to
		// whoever reported most recently.
		let focus = _focusedOwner(among: display)
		_focusOwner = focus

		let report = focus.flatMap { _reports[$0] }

		// Lead the summary with whoever the bar is following, so the name and
		// the numbers can't describe two different jobs. The rest keep their
		// order — they're still holding the keep-alive and still worth naming.
		let named: [String]
		if let focus, let index = display.firstIndex(of: focus) {
			var reordered = display
			reordered.remove(at: index)
			named = [focus] + reordered
		} else {
			named = display
		}

		let state = KeepAliveAttributes.ContentState(
			isRunning: isRunning,
			owners: named,
			completed: report?.completed,
			total: report?.total,
			progressFraction: report?.fraction,
			detail: report?.detail
		)

		guard _activity != nil else {
			// There is a window inside `_drain` where the old activity has been
			// detached and the replacement hasn't been requested yet. Starting a
			// second one in that gap would leave two pills fighting over the
			// same attributes type, so hand the state to the drain instead.
			if _pushInFlight {
				_pendingState = state
				return
			}

			_start(with: state)
			return
		}

		// Nothing to say — don't spend a system update on it. Compared against
		// what's actually on screen *and* what's already queued to go, since
		// `_lastState` is no longer written until delivery confirms.
		guard state != _lastState, state != _pendingState, state != _inFlightState else { return }

		_pendingState = state
		_drain()
	}

	// MARK: - Pushing

	// The newest state waiting to go out. One slot, deliberately: if three
	// states are produced while one update is in flight, only the last of them
	// is worth sending.
	private var _pendingState: KeepAliveAttributes.ContentState?

	// Whether an `update()` is in flight. Only one at a time — `Task` is not
	// FIFO, and two overlapping updates can land in the wrong order.
	private var _pushInFlight = false

	// The state currently being delivered. Without it, an identical state
	// arriving from `sync` while a push was in flight passed both checks —
	// `_lastState` was still the old value and `_pendingState` had been taken —
	// and got queued a second time. That was every duplicate push in the logs,
	// and every one of them spent budget on a frame that was already on screen.
	private var _inFlightState: KeepAliveAttributes.ContentState?

	// Ends the current activity and requests a fresh one carrying the new state,
	// rather than calling `update()` on the existing one.
	//
	// This is deliberate and it is a diagnostic as much as a fix. Every
	// `update()` in the logs was accepted — awaited, returned, no throw — and
	// none of them ever reached the screen during an install. The only call that
	// has *ever* painted reliably is `Activity.request`, which is what puts the
	// first frame up. So this stops using the call that doesn't work and uses the
	// one that does.
	//
	// If the count now moves, the problem was `update()` delivery specifically
	// and this is the fix. If the re-request also fails to paint, the log will
	// say so with an actual error — and that rules out update budgets entirely,
	// because `request` is a different path with its own limits.
	//
	// Cost: the pill tears down and rebuilds on every count change, so expect a
	// visible blink per app. Worth it to find out; not necessarily worth keeping.
	private func _drain() {
		guard !_pushInFlight,
			  let activity = _activity,
			  let next = _pendingState
		else { return }

		_pendingState = nil
		_pushInFlight = true
		_inFlightState = next

		// Detached *before* the end call, so `_watchActivityState`'s identity
		// guard fails and a teardown we asked for can't be mistaken for the user
		// swiping the pill away — which would set `_nextAttempt` 30s out and stop
		// the replacement being requested at all.
		_activity = nil

		Task { [weak self] in
			await activity.end(nil, dismissalPolicy: .immediate)

			await MainActor.run {
				guard let self else { return }

				self._pushInFlight = false
				self._inFlightState = nil

				self._rerequest(next)
				self._drain()
			}
		}
	}

	private func _rerequest(_ state: KeepAliveAttributes.ContentState) {
		do {
			_activity = try Activity.request(
				attributes: KeepAliveAttributes(startedAt: Date()),
				content: ActivityContent(state: state, staleDate: nil),
				pushType: nil
			)

			_lastState = state
			_nextAttempt = .distantPast

			BackgroundAudioStatus.shared.record(
				.island,
				"re-requested — \(state.countLabel ?? "no count") · \(state.summaryLine)"
			)

			_watchActivityState()
		} catch {
			// The interesting failure. `update()` never told us anything; this
			// will.
			_lastState = nil
			_nextAttempt = Date().addingTimeInterval(Self._retryDelay)

			BackgroundAudioStatus.shared.record(
				.island,
				"re-request FAILED — \(error.localizedDescription)"
			)
		}
	}

	// Called by whatever is doing the work. Pass nil for `total` when a batch
	// finishes, so a stale "12 of 12" can't sit under the next owner's name.
	//
	// Cheap to call on a timer: the state comparison in `sync` drops anything
	// that hasn't actually changed before it reaches the system.
	// Batch position. Pass nil for `total` to drop the count without disturbing
	// the phase text.
	func report(_ owner: BackgroundAudioManager.Owner, completed: Int, total: Int?) {
		_merge(owner) {
			if let total, total > 0 {
				$0.completed = completed
				$0.total = total
			} else {
				$0.completed = nil
				$0.total = nil
			}
		}
	}

	// A real 0–1 figure, where the owner has one.
	//
	// Use this only where the figure is genuinely cheap to move — it changes
	// continuously by definition, so every report is a distinct state and a
	// system update. Installs used to feed `aggregateProgress` in here from a
	// 0.4s timer, which is roughly 150 updates a minute for the length of a
	// batch; ActivityKit budgets local updates and simply stopped delivering
	// them partway through. The app count is what the pill shows now.
	func report(_ owner: BackgroundAudioManager.Owner, fraction: Double?) {
		_merge(owner) { $0.fraction = fraction }
	}

	// The phase the work is in, using whatever label the app already computes
	// for its own UI. Report this on phase *transitions*, not on a tick.
	func report(_ owner: BackgroundAudioManager.Owner, detail: String?) {
		_merge(owner) { $0.detail = detail }
	}

	// Everything this owner has said, withdrawn at once. Call it when a batch
	// ends: a report left behind outlives the work it described, and the next
	// time that owner comes back into focus the pill opens on a stale count.
	func clearReport(_ owner: BackgroundAudioManager.Owner) {
		_merge(owner) { $0 = _Report() }
	}

	private func _merge(_ owner: BackgroundAudioManager.Owner, _ change: @escaping (inout _Report) -> Void) {
		_onMain { self._mergeOnMain(owner, change) }
	}

	private func _mergeOnMain(_ owner: BackgroundAudioManager.Owner, _ change: (inout _Report) -> Void) {
		let key = owner.displayName

		var report = _reports[key] ?? _Report()
		let before = report
		change(&report)

		if report == _Report() {
			_reports.removeValue(forKey: key)
			_reportSeq.removeValue(forKey: key)

			// Focus has to move on too, or the pill keeps naming an owner it
			// has no numbers for.
			if _focusOwner == key { _focusOwner = nil }
		} else {
			_reports[key] = report

			if report != before {
				_sequence += 1
				_reportSeq[key] = _sequence
			}
		}

		// The old `_activity != nil` half of this guard is gone. It was there to
		// stop a seeded "0 of N" ending an activity that hadn't started, but
		// `_apply` can't end anything on its own — `wanted` decides that, and it
		// reads the keep-alive, not the report. All the guard did was silently
		// swallow reports that landed between publishes.
		guard report != before else { return }

		// Upstream half of the trace. One line per report that actually
		// changed something, so a run can be read as: did seven counts arrive
		// here, and did seven pushes leave `_drain`.
		BackgroundAudioStatus.shared.record(.island, "report — \(key): \(Self._describe(report))")

		_apply(isRunning: _lastIsRunning, owners: _lastOwnersInput)
	}

	private static func _describe(_ report: _Report) -> String {
		var parts: [String] = []

		if let completed = report.completed, let total = report.total {
			parts.append("\(completed) of \(total)")
		}

		if let detail = report.detail, !detail.isEmpty {
			parts.append(detail)
		}

		return parts.isEmpty ? "withdrawn" : parts.joined(separator: " · ")
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
			_watchActivityState()
		} catch {
			_nextAttempt = Date().addingTimeInterval(Self._retryDelay)

			Logger.misc.error("Keep-alive Live Activity failed to start: \(error.localizedDescription)")
			BackgroundAudioStatus.shared.record(.island, "failed to start — \(error.localizedDescription)")
		}
	}

	// Notices when the pill stops existing behind our back.
	//
	// Nothing else did. `_activity` was set once and never reconciled with the
	// system's view of it, so swiping the pill away — or the system reclaiming
	// it after too many updates — left a handle that still looked live. Every
	// `update()` after that went nowhere, silently, and nothing ever
	// re-requested, so the pill was gone for the rest of the run.
	//
	// Coming back is deliberately not instant: `_retryDelay` sits between a
	// dismissal and the next request so a pill the *user* swiped away doesn't
	// snap straight back, while one iOS took stops being permanent.
	private func _watchActivityState() {
		guard let activity = _activity else { return }

		let id = activity.id

		Task { [weak self] in
			for await state in activity.activityStateUpdates {
				guard state == .dismissed || state == .ended else { continue }

				await MainActor.run {
					guard let self, self._activity?.id == id else { return }

					self._activity = nil
					self._lastState = nil
					self._nextAttempt = Date().addingTimeInterval(Self._retryDelay)

					BackgroundAudioStatus.shared.record(.island, "went away on its own — will try again in \(Int(Self._retryDelay))s if work is still running")
				}

				break
			}
		}
	}

	private func _end() {
		guard let activity = _activity else { return }

		_activity = nil
		_lastState = nil
		_lastOwners = []
		_reports.removeAll()
		_reportSeq.removeAll()
		_pendingState = nil
		_inFlightState = nil
		_focusOwner = nil
		_lastIsRunning = false
		_lastOwnersInput = []

		BackgroundAudioStatus.shared.record(.island, "dismissed — nothing left holding the keep-alive")

		Task {
			// `.immediate` rather than letting it linger on the Lock Screen.
			// The keep-alive is over the moment the last claim goes; a pill
			// that hangs around afterwards would be saying something untrue.
			await activity.end(nil, dismissalPolicy: .immediate)
		}
	}
}

//
//  KeepAliveActivityController.swift
//  Ksign
//

import ActivityKit
import Foundation
import OSLog

// Starts, updates and ends the keep-alive Live Activity.
//
// Background execution is owned by `BackgroundAudioManager`; this controller
// only mirrors work that is already running into ActivityKit. Its state and
// pacing run on a dedicated serial queue rather than the main actor. Signing,
// archiving and install polling all continue on worker queues while the app is
// backgrounded, so making ActivityKit delivery depend on the UI run loop can
// leave updates queued until the app becomes active again.
@available(iOS 16.2, *)
final class KeepAliveActivityController {
	static let shared = KeepAliveActivityController()

	private let _queue = DispatchQueue(
		label: "nya.asami.ksign.live-activity",
		qos: .userInitiated
	)

	// Every mutable field below is confined to `_queue`.
	private var _activity: Activity<KeepAliveAttributes>?

	// The last owners that were actually holding something. During the audio
	// manager's linger gap between two items in a batch, keep showing the previous
	// owner instead of tearing the activity down and rebuilding it.
	private var _lastOwners: [String] = []

	// What each owner has told us about itself. Fields are merged rather than
	// replaced, so a batch can own the count while the worker owns the phase text.
	private struct _Report: Equatable {
		var completed: Int?
		var total: Int?
		var fraction: Double?
		var detail: String?
		var detailStartedAt: Date?
	}

	private var _reports: [String: _Report] = [:]

	// Most-recent report wins when the current focus disappears. The focused
	// owner remains sticky while it is still active so the bar cannot ping-pong
	// between simultaneous operations.
	private var _sequence: UInt64 = 0
	private var _reportSeq: [String: UInt64] = [:]
	private var _focusOwner: String?

	// Reports and audio-state publications arrive independently. Keep the latest
	// values so either path can rebuild the complete ActivityKit state.
	private var _lastIsRunning = false
	private var _lastOwnersInput: [String] = []
	private var _featureEnabled = true

	// A failed request normally means Live Activities are disabled or temporarily
	// unavailable. Avoid retrying continuously while work is running.
	private var _nextAttempt = Date.distantPast
	private static let _retryDelay: TimeInterval = 30

	// MARK: - Serialized ActivityKit delivery

	// Producers may report as often as they need. Only the newest desired state
	// is retained, and exactly one Activity.update call is in flight at a time.
	private var _desiredState: KeepAliveAttributes.ContentState?
	private var _pendingUrgentPush = false
	private var _pushInFlight = false
	private var _scheduledPush: DispatchWorkItem?
	private var _lastPushedState: KeepAliveAttributes.ContentState?
	private var _lastPushAt = Date.distantPast

	// Phase, owner, count and completion transitions should feel immediate, but a
	// tiny floor still coalesces bursts. Fraction-only movement is intentionally
	// slower so a fast poller does not flood ActivityKit.
	private static let _urgentPushInterval: TimeInterval = 0.35
	private static let _progressPushInterval: TimeInterval = 3

	// Fractions are quantized to whole percentage points before entering the
	// state graph. A producer can sample frequently without creating a distinct
	// ActivityKit state for microscopic changes.
	private static let _progressStep = 0.01

	private init() { }

	// MARK: - Driven by BackgroundAudioStatus

	func sync(isRunning: Bool, owners: [String]) {
		// Capture the switch at the call site. The controller does not mutate this
		// setting and should not have to hop to the UI actor to read it later.
		let enabled = OptionsManager.shared.options.backgroundAudio

		_queue.async {
			self._featureEnabled = enabled
			self._lastIsRunning = isRunning
			self._lastOwnersInput = owners
			self._apply(isRunning: isRunning, owners: owners)
		}
	}

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
		let wanted = _featureEnabled && (isRunning || !owners.isEmpty)

		guard wanted else {
			_end()
			return
		}

		if !owners.isEmpty { _lastOwners = owners }
		let display = owners.isEmpty ? _lastOwners : owners

		let focus = _focusedOwner(among: display)
		_focusOwner = focus
		let report = focus.flatMap { _reports[$0] }

		// Lead with the owner whose progress is being displayed so the title and
		// progress can never describe different jobs.
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
			detail: report?.detail,
			detailStartedAt: report?.detailStartedAt
		)

		// A newly requested activity already contains this state, so there is no
		// reason to immediately update it again. If the request fails, retain the
		// desired state and let the serial scheduler retry after the backoff.
		if _activity == nil {
			_start(with: state)
			if _activity != nil { return }
		}

		let prior = _desiredState ?? _lastPushedState
		_enqueue(state, urgent: _isUrgentTransition(from: prior, to: state))
	}

	private func _isUrgentTransition(
		from old: KeepAliveAttributes.ContentState?,
		to new: KeepAliveAttributes.ContentState
	) -> Bool {
		guard let old else { return true }

		if old.isRunning != new.isRunning
			|| old.owners != new.owners
			|| old.completed != new.completed
			|| old.total != new.total
			|| old.detail != new.detail {
			return true
		}

		// A fraction appearing/disappearing or reaching completion should not wait
		// behind the ordinary progress cadence.
		if old.progressFraction == nil || new.progressFraction == nil {
			return old.progressFraction != new.progressFraction
		}

		return (old.progressFraction ?? 0) < 1 && (new.progressFraction ?? 0) >= 1
	}

	private func _enqueue(_ state: KeepAliveAttributes.ContentState, urgent: Bool) {
		// Nothing changed and nothing newer is waiting.
		guard state != _lastPushedState || _desiredState != nil else { return }

		_desiredState = state
		_pendingUrgentPush = _pendingUrgentPush || urgent

		// If a progress update was waiting on the slower cadence and an urgent
		// transition arrives, replace the scheduled wake-up with the earlier one.
		if urgent, let scheduled = _scheduledPush {
			scheduled.cancel()
			_scheduledPush = nil
		}

		_schedulePushIfNeeded()
	}

	private func _schedulePushIfNeeded() {
		guard !_pushInFlight, _scheduledPush == nil, let desired = _desiredState else { return }

		if desired == _lastPushedState {
			_desiredState = nil
			_pendingUrgentPush = false
			return
		}

		if _activity == nil {
			if Date() >= _nextAttempt {
				_start(with: desired)
				if _activity != nil { return }
			}

			let delay = max(0.25, min(1.0, _nextAttempt.timeIntervalSinceNow))
			_schedule(after: delay)
			return
		}

		let minimumInterval = _pendingUrgentPush
			? Self._urgentPushInterval
			: Self._progressPushInterval
		let remaining = minimumInterval - Date().timeIntervalSince(_lastPushAt)

		if remaining > 0 {
			_schedule(after: remaining)
		} else {
			_beginPush()
		}
	}

	private func _schedule(after delay: TimeInterval) {
		let item = DispatchWorkItem { [weak self] in
			guard let self else { return }
			self._scheduledPush = nil
			self._schedulePushIfNeeded()
		}

		_scheduledPush = item
		_queue.asyncAfter(deadline: .now() + max(0.01, delay), execute: item)
	}

	private func _beginPush() {
		guard !_pushInFlight,
		      let activity = _activity,
		      let state = _desiredState else { return }

		_pushInFlight = true
		let activityID = activity.id
		let stateBeingPushed = state
		let wasUrgent = _pendingUrgentPush
		_pendingUrgentPush = false

		// This task is intentionally created from the controller's worker queue and
		// has no MainActor annotation. ActivityKit supports background updates; the
		// delivery path must not wait for SwiftUI's run loop to become active again.
		Task(priority: .userInitiated) { [weak self] in
			await activity.update(ActivityContent(state: stateBeingPushed, staleDate: nil))

			self?._queue.async {
				self?._finishPush(
					activityID: activityID,
					state: stateBeingPushed,
					wasUrgent: wasUrgent
				)
			}
		}
	}

	private func _finishPush(
		activityID: String,
		state: KeepAliveAttributes.ContentState,
		wasUrgent: Bool
	) {
		_pushInFlight = false

		// Ignore completion from an activity that was replaced while the await was
		// in flight. The newest desired state remains queued for the replacement.
		guard _activity?.id == activityID else {
			_schedulePushIfNeeded()
			return
		}

		_lastPushedState = state
		_lastPushAt = Date()

		if _desiredState == state {
			_desiredState = nil
			_pendingUrgentPush = false
		}

		let count = "\(state.completed.map(String.init) ?? "–")/\(state.total.map(String.init) ?? "–")"
		let percent = state.progressFraction
			.map { " · \(Int(($0 * 100).rounded()))%" }
			?? ""
		BackgroundAudioStatus.shared.record(
			.island,
			"pushed\(wasUrgent ? "" : " progress") — \(count)\(percent) — \(state.summaryLine)"
		)

		_schedulePushIfNeeded()
	}

	private func _stopPusher() {
		_scheduledPush?.cancel()
		_scheduledPush = nil
		_desiredState = nil
		_pendingUrgentPush = false
		_pushInFlight = false
		_lastPushedState = nil
		_lastPushAt = .distantPast
	}

	// MARK: - Work reports

	// Batch position. Pass nil for `total` to withdraw the count without
	// disturbing the phase or fraction.
	func report(_ owner: BackgroundAudioManager.Owner, completed: Int, total: Int?) {
		_merge(owner) {
			if let total, total > 0 {
				$0.completed = max(0, min(completed, total))
				$0.total = total
			} else {
				$0.completed = nil
				$0.total = nil
			}
		}
	}

	// A genuine 0...1 figure. Producers may call this frequently; values are
	// quantized here and the serial scheduler applies the three-second cadence.
	func report(_ owner: BackgroundAudioManager.Owner, fraction: Double?) {
		_merge(owner) {
			guard let fraction else {
				$0.fraction = nil
				return
			}

			let clamped = min(1, max(0, fraction))
			if clamped >= 1 {
				$0.fraction = 1
			} else {
				let units = floor((clamped + 0.000_000_001) / Self._progressStep)
				$0.fraction = min(1 - Self._progressStep, units * Self._progressStep)
			}
		}
	}

	// Phase changes reset the system-rendered elapsed timer. Repeating the same
	// phase does not reset it or generate a new state.
	func report(_ owner: BackgroundAudioManager.Owner, detail: String?) {
		_merge(owner) {
			let normalized = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
			let value = (normalized?.isEmpty == false) ? normalized : nil
			guard $0.detail != value else { return }

			$0.detail = value
			$0.detailStartedAt = value == nil ? nil : Date()
		}
	}

	func clearReport(_ owner: BackgroundAudioManager.Owner) {
		_merge(owner) { $0 = _Report() }
	}

	private func _merge(_ owner: BackgroundAudioManager.Owner, _ change: @escaping (inout _Report) -> Void) {
		let key = owner.displayName

		_queue.async {
			var report = self._reports[key] ?? _Report()
			let before = report
			change(&report)

			guard report != before else { return }

			if report == _Report() {
				self._reports.removeValue(forKey: key)
				self._reportSeq.removeValue(forKey: key)
				if self._focusOwner == key { self._focusOwner = nil }
			} else {
				self._reports[key] = report
				self._sequence += 1
				self._reportSeq[key] = self._sequence
			}

			// Several workflows seed their count before they claim the keep-alive.
			// Retain that report until the next audio publication instead of treating
			// the temporary absence of an owner as the end of an activity.
			if self._activity == nil,
			   !self._lastIsRunning,
			   self._lastOwnersInput.isEmpty {
				return
			}

			self._apply(isRunning: self._lastIsRunning, owners: self._lastOwnersInput)
		}
	}

	// MARK: - Lifecycle

	private func _start(with state: KeepAliveAttributes.ContentState) {
		guard Date() >= _nextAttempt else {
			_desiredState = state
			_schedulePushIfNeeded()
			return
		}

		guard ActivityAuthorizationInfo().areActivitiesEnabled else {
			_desiredState = state
			_nextAttempt = Date().addingTimeInterval(Self._retryDelay)
			Logger.misc.error("Live Activities are disabled for this app — keep-alive pill can't be shown.")
			BackgroundAudioStatus.shared.record(.island, "can't show — Live Activities are turned off for ASign")
			_schedulePushIfNeeded()
			return
		}

		do {
			_activity = try Activity.request(
				attributes: KeepAliveAttributes(startedAt: Date()),
				content: ActivityContent(state: state, staleDate: nil),
				pushType: nil
			)

			_lastPushedState = state
			_lastPushAt = Date()
			_nextAttempt = .distantPast

			if _desiredState == state {
				_desiredState = nil
				_pendingUrgentPush = false
			}

			BackgroundAudioStatus.shared.record(.island, "showing — \(state.summary)")
			_watchActivityState()
		} catch {
			_desiredState = state
			_nextAttempt = Date().addingTimeInterval(Self._retryDelay)
			Logger.misc.error("Keep-alive Live Activity failed to start: \(error.localizedDescription)")
			BackgroundAudioStatus.shared.record(.island, "failed to start — \(error.localizedDescription)")
			_schedulePushIfNeeded()
		}
	}

	private func _watchActivityState() {
		guard let activity = _activity else { return }
		let id = activity.id

		Task(priority: .utility) { [weak self] in
			for await state in activity.activityStateUpdates {
				guard state == .dismissed || state == .ended else { continue }

				self?._queue.async {
					guard let self, self._activity?.id == id else { return }

					self._activity = nil
					self._lastPushedState = nil
					self._lastPushAt = .distantPast
					self._nextAttempt = Date().addingTimeInterval(Self._retryDelay)

					BackgroundAudioStatus.shared.record(
						.island,
						"went away on its own — will try again in \(Int(Self._retryDelay))s if work is still running"
					)

					// Rebuild the current truth now. The scheduler retains it during
					// the backoff and recreates the activity without another report.
					self._apply(
						isRunning: self._lastIsRunning,
						owners: self._lastOwnersInput
					)
				}

				break
			}
		}
	}

	private func _end() {
		guard let activity = _activity else {
			_stopPusher()
			_reports.removeAll()
			_reportSeq.removeAll()
			_focusOwner = nil
			_lastOwners = []
			return
		}

		_activity = nil
		_lastOwners = []
		_stopPusher()
		_reports.removeAll()
		_reportSeq.removeAll()
		_focusOwner = nil
		_lastIsRunning = false
		_lastOwnersInput = []

		BackgroundAudioStatus.shared.record(.island, "dismissed — nothing left holding the keep-alive")

		Task(priority: .utility) {
			await activity.end(nil, dismissalPolicy: .immediate)
		}
	}
}

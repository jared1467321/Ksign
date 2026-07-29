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
// only mirrors the work that is already running into ActivityKit. All state is
// confined to the main queue so reports from signing, importing and installing
// cannot race each other.
@available(iOS 16.2, *)
final class KeepAliveActivityController {
	static let shared = KeepAliveActivityController()

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
	// between two simultaneous operations.
	private var _sequence: UInt64 = 0
	private var _reportSeq: [String: UInt64] = [:]
	private var _focusOwner: String?

	// Reports and audio-state publications arrive independently. Keep the latest
	// audio values so either path can rebuild the complete ActivityKit state.
	private var _lastIsRunning = false
	private var _lastOwnersInput: [String] = []

	// A failed request normally means Live Activities are disabled or temporarily
	// unavailable. Avoid retrying continuously while work is running.
	private var _nextAttempt = Date.distantPast
	private static let _retryDelay: TimeInterval = 30

	// MARK: - Serialized ActivityKit delivery

	// Producers may report as often as they need. Only the newest desired state
	// is retained, and one task serially hands updates to ActivityKit. This avoids
	// out-of-order fire-and-forget updates and prevents progress sampling from
	// flooding the system.
	private var _desiredState: KeepAliveAttributes.ContentState?
	private var _pendingUrgentPush = false
	private var _pushTask: Task<Void, Never>?
	private var _lastPushedState: KeepAliveAttributes.ContentState?
	private var _lastPushAt = Date.distantPast

	// Phase, owner, count and completion transitions should feel immediate, but a
	// tiny floor still coalesces bursts such as several jobs changing phase at the
	// same time. Fraction-only movement is intentionally slower.
	private static let _urgentPushInterval: TimeInterval = 0.35
	private static let _progressPushInterval: TimeInterval = 3

	// Fractions are quantized to whole percentage points before entering the
	// state graph. The session can sample every 0.4 seconds without creating a
	// distinct ActivityKit state for every microscopic change.
	private static let _progressStep = 0.01

	private init() { }

	// MARK: - Queue confinement

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
		// The activity follows the existing feature switch. This does not alter or
		// control the audio engine; it only decides whether the indicator is shown.
		let enabled = OptionsManager.shared.options.backgroundAudio
		let wanted = enabled && (isRunning || !owners.isEmpty)

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
		// desired state and let the serialized task retry after the backoff.
		if _activity == nil {
			_start(with: state)
			if _activity != nil { return }
		}

		_enqueue(state, urgent: _isUrgentTransition(from: _desiredState ?? _lastPushedState, to: state))
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
		_startPusherIfNeeded()
	}

	private func _startPusherIfNeeded() {
		guard _pushTask == nil else { return }

		_pushTask = Task { @MainActor [weak self] in
			while !Task.isCancelled {
				guard let self else { return }
				guard let desired = self._desiredState else {
					self._pushTask = nil
					return
				}

				// If the activity disappeared or a request failed, retry the current
				// truth after the existing backoff. No producer has to emit another
				// report just to resurrect the indicator.
				if self._activity == nil {
					if Date() >= self._nextAttempt {
						self._start(with: desired)
					}

					if self._activity == nil {
						let delay = max(0.25, min(1.0, self._nextAttempt.timeIntervalSinceNow))
						try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
						continue
					}

					// `_start` seeded the activity with the desired state.
					if self._desiredState == nil { continue }
				}

				guard let activity = self._activity,
				      let state = self._desiredState else { continue }

				if state == self._lastPushedState {
					self._desiredState = nil
					self._pendingUrgentPush = false
					continue
				}

				let minimumInterval = self._pendingUrgentPush
					? Self._urgentPushInterval
					: Self._progressPushInterval
				let remaining = minimumInterval - Date().timeIntervalSince(self._lastPushAt)

				if remaining > 0 {
					try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
					continue
				}

				let activityID = activity.id
				let stateBeingPushed = state
				let wasUrgent = self._pendingUrgentPush
				self._pendingUrgentPush = false

				await activity.update(ActivityContent(state: stateBeingPushed, staleDate: nil))

				// Ignore completion from an activity that was replaced while the await
				// was in flight.
				guard self._activity?.id == activityID else { continue }

				self._lastPushedState = stateBeingPushed
				self._lastPushAt = Date()

				if self._desiredState == stateBeingPushed {
					self._desiredState = nil
					self._pendingUrgentPush = false
				}

				let count = "\(stateBeingPushed.completed.map(String.init) ?? "–")/\(stateBeingPushed.total.map(String.init) ?? "–")"
				let percent = stateBeingPushed.progressFraction
					.map { " · \(Int(($0 * 100).rounded()))%" }
					?? ""
				BackgroundAudioStatus.shared.record(
					.island,
					"pushed\(wasUrgent ? "" : " progress") — \(count)\(percent) — \(stateBeingPushed.summaryLine)"
				)
			}
		}
	}

	private func _stopPusher() {
		_pushTask?.cancel()
		_pushTask = nil
		_desiredState = nil
		_pendingUrgentPush = false
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
	// quantized here and the serialized pusher applies the three-second cadence.
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
		_onMain { self._mergeOnMain(owner, change) }
	}

	private func _mergeOnMain(_ owner: BackgroundAudioManager.Owner, _ change: (inout _Report) -> Void) {
		let key = owner.displayName
		var report = _reports[key] ?? _Report()
		let before = report
		change(&report)

		guard report != before else { return }

		if report == _Report() {
			_reports.removeValue(forKey: key)
			_reportSeq.removeValue(forKey: key)
			if _focusOwner == key { _focusOwner = nil }
		} else {
			_reports[key] = report
			_sequence += 1
			_reportSeq[key] = _sequence
		}

		// Several workflows seed their count before they claim the keep-alive.
		// Retain that report until the next audio publication instead of treating
		// the temporary absence of an owner as the end of an activity.
		if _activity == nil, !_lastIsRunning, _lastOwnersInput.isEmpty { return }

		_apply(isRunning: _lastIsRunning, owners: _lastOwnersInput)
	}

	// MARK: - Lifecycle

	private func _start(with state: KeepAliveAttributes.ContentState) {
		guard Date() >= _nextAttempt else { return }

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
			_nextAttempt = Date().addingTimeInterval(Self._retryDelay)
			Logger.misc.error("Keep-alive Live Activity failed to start: \(error.localizedDescription)")
			BackgroundAudioStatus.shared.record(.island, "failed to start — \(error.localizedDescription)")
		}
	}

	private func _watchActivityState() {
		guard let activity = _activity else { return }
		let id = activity.id

		Task { [weak self] in
			for await state in activity.activityStateUpdates {
				guard state == .dismissed || state == .ended else { continue }

				await MainActor.run {
					guard let self, self._activity?.id == id else { return }

					self._activity = nil
					self._lastPushedState = nil
					self._lastPushAt = .distantPast
					self._nextAttempt = Date().addingTimeInterval(Self._retryDelay)

					BackgroundAudioStatus.shared.record(
						.island,
						"went away on its own — will try again in \(Int(Self._retryDelay))s if work is still running"
					)

					// Rebuild the current truth now. The pusher retains it during the
					// backoff and recreates the activity without requiring a new report.
					self._apply(isRunning: self._lastIsRunning, owners: self._lastOwnersInput)
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

		Task {
			await activity.end(nil, dismissalPolicy: .immediate)
		}
	}
}

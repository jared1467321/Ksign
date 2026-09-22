//
//  KeepAliveActivityController.swift
//  Ksign
//

import ActivityKit
import Foundation
import OSLog
import UIKit
import NimbleExtensions

// Owns the app's single local Live Activity.
//
// The important separation is:
// - BackgroundAudioManager owns background execution.
// - Work owners/reporters own whether there is a real job to display.
// - This controller owns ActivityKit lifetime and serialization only.
//
// A Live Activity is requested while the app is foregrounded, then the same
// Activity instance survives foreground/background transitions until the work
// ends. Local Activity.update calls are allowed while the app has background
// execution time, so updates are not tied to SwiftUI or UIApplication state.
@available(iOS 16.2, *)
final class KeepAliveActivityController {
	static let shared = KeepAliveActivityController()

	private let _queue = DispatchQueue(
		label: "nya.asami.ksign.live-activity",
		qos: .userInitiated
	)

	// MARK: - Activity lifetime

	private var _activity: Activity<KeepAliveAttributes>?
	private var _appIsActive = false
	private var _featureEnabled = true
	private var _audioIsRunning = false
	private var _activeOwners: [String] = []
	private var _handoffOwners: [String] = []

	// If a person or the system dismisses the current activity, don't immediately
	// recreate it for the same work. Once all owners are gone, the next job gets a
	// fresh chance to create one.
	private var _suppressedForCurrentWork = false

	// When the last owner releases, BackgroundAudioManager deliberately keeps its
	// audio graph alive for a short handoff window. `_handoffOwners` mirrors that
	// exact window so a download -> import -> sign/install chain keeps one Activity
	// without maintaining a second, competing timer here.

	// Request failures shouldn't become a hot loop while progress callbacks are
	// arriving rapidly.
	private var _nextStartAttempt = Date.distantPast
	private static let _retryDelay: TimeInterval = 15

	private var _lifecycleObservers: [NSObjectProtocol] = []

	// MARK: - Work reports

	private struct _Report: Equatable {
		var completed: Int?
		var total: Int?
		var fraction: Double?
		var detail: String?
		var detailStartedAt: Date?
	}

	private var _reports: [String: _Report] = [:]
	private var _sequence: UInt64 = 0
	private var _reportSeq: [String: UInt64] = [:]
	private var _focusOwner: String?

	// Producers may report very frequently. Progress is reduced to human-visible
	// one-percent steps before ActivityKit sees it; phase/count/owner changes are
	// never delayed by an arbitrary timer.
	private static let _progressStep = 0.01

	// MARK: - Serialized ActivityKit delivery

	// Activity.update is serialized. While one update is in flight, newer state
	// simply replaces the pending state. This prevents stale callbacks from
	// building an unbounded queue without inventing a timing quota.
	private var _desiredState: KeepAliveAttributes.ContentState?
	private var _updateInFlight = false
	private var _inFlightState: KeepAliveAttributes.ContentState?
	private var _lastDeliveredState: KeepAliveAttributes.ContentState?
	private var _reconcileScheduled = false

	private init() {
		let center = NotificationCenter.default

		_lifecycleObservers.append(
			center.addObserver(
				forName: UIApplication.didBecomeActiveNotification,
				object: nil,
				queue: .main
			) { [weak self] _ in
				self?._setAppActive(true)
			}
		)

		_lifecycleObservers.append(
			center.addObserver(
				forName: UIApplication.willResignActiveNotification,
				object: nil,
				queue: .main
			) { [weak self] _ in
				self?._setAppActive(false)
			}
		)

		// The singleton can first be touched from a worker queue. Read UIKit state
		// on main, then adopt any surviving Activity from a prior process lifetime.
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			let active = UIApplication.shared.applicationState == .active
			let existing = Activity<KeepAliveAttributes>.activities

			self._queue.async {
				self._appIsActive = active
				self._adoptExistingActivity(existing)
				self._reconcile()
			}
		}
	}

	deinit {
		let center = NotificationCenter.default
		for observer in _lifecycleObservers {
			center.removeObserver(observer)
		}
	}

	// MARK: - Driven by BackgroundAudioStatus

	func sync(isRunning: Bool, owners: [String]) {
		let enabled = OptionsManager.shared.options.backgroundAudio

		_queue.async {
			let previousOwners = self._activeOwners
			let hadWork = !previousOwners.isEmpty
			let hasWork = !owners.isEmpty

			self._featureEnabled = enabled
			self._audioIsRunning = isRunning
			self._activeOwners = owners

			if hadWork && !hasWork {
				// The audio manager itself owns the handoff window. Keep the final
				// owner visible for exactly as long as that graph is still running so
				// a terminal report or the next pipeline owner can reuse this Activity.
				self._handoffOwners = previousOwners
			} else if hasWork {
				self._handoffOwners = []
				if !hadWork {
					self._suppressedForCurrentWork = false
					self._nextStartAttempt = .distantPast
				}
			}

			// Once the audio manager says its linger is actually over, the job is
			// over too. Reset dismissal suppression now so the next independent job
			// gets a fresh Activity.
			if !hasWork && !isRunning {
				self._handoffOwners = []
				self._focusOwner = nil
				self._suppressedForCurrentWork = false
			}

			self._scheduleReconcile()
		}
	}

	private func _setAppActive(_ active: Bool) {
		_queue.async {
			self._appIsActive = active
			if active {
				// A request may have failed only because the app was transitioning
				// out of the foreground. Returning active is the right retry point.
				self._nextStartAttempt = .distantPast
			}
			self._scheduleReconcile()
		}
	}

	private func _adoptExistingActivity(_ activities: [Activity<KeepAliveAttributes>]) {
		guard _activity == nil, let first = activities.first else { return }

		_activity = first
		_lastDeliveredState = first.content.state
		_watchActivityState(first)

		BackgroundAudioStatus.shared.record(
			.island,
			"adopted existing activity — \(first.content.state.summary)"
		)

		// There should only be one Ksign keep-alive activity. Clean up leftovers
		// from a crash/relaunch race rather than letting duplicate islands survive.
		for extra in activities.dropFirst() {
			Task(priority: .utility) {
				await extra.end(nil, dismissalPolicy: .immediate)
			}
		}
	}

	// MARK: - State construction

	private func _focusedOwner(among owners: [String]) -> String? {
		if let current = _focusOwner,
		   owners.contains(current),
		   _reports[current] != nil {
			return current
		}

		var best: String?
		var bestSeq: UInt64 = 0

		for owner in owners where _reports[owner] != nil {
			let seq = _reportSeq[owner] ?? 0
			if best == nil || seq > bestSeq {
				best = owner
				bestSeq = seq
			}
		}

		return best
	}

	private func _currentState() -> KeepAliveAttributes.ContentState? {
		let displayOwners = _activeOwners.isEmpty ? _handoffOwners : _activeOwners
		guard !displayOwners.isEmpty else { return nil }

		let focus = _focusedOwner(among: displayOwners)
		_focusOwner = focus
		let report = focus.flatMap { _reports[$0] }

		let named: [String]
		if let focus, let index = displayOwners.firstIndex(of: focus) {
			var reordered = displayOwners
			reordered.remove(at: index)
			named = [focus] + reordered
		} else {
			named = displayOwners
		}

		return KeepAliveAttributes.ContentState(
			isRunning: _audioIsRunning,
			owners: named,
			completed: report?.completed,
			total: report?.total,
			progressFraction: report?.fraction,
			detail: report?.detail,
			detailStartedAt: report?.detailStartedAt,
			theme: _themeSnapshot()
		)
	}

	func refreshTheme() {
		_queue.async {
			self._scheduleReconcile()
		}
	}

	private func _themeSnapshot() -> KeepAliveThemeSnapshot {
		func color(_ role: NBThemeRole) -> KeepAliveThemeColor {
			let value = NBHalloween.themeColor(role)
			return KeepAliveThemeColor(
				red: value.red,
				green: value.green,
				blue: value.blue,
				alpha: value.alpha
			)
		}

		return KeepAliveThemeSnapshot(
			background: color(.liveActivityBackground),
			actionText: color(.liveActivityActionText),
			primaryText: color(.liveActivityPrimaryText),
			secondaryText: color(.liveActivitySecondaryText),
			running: color(.liveActivityRunning),
			idle: color(.liveActivityIdle)
		)
	}

	private func _scheduleReconcile() {
		guard !_reconcileScheduled else { return }
		_reconcileScheduled = true

		_queue.async { [weak self] in
			guard let self else { return }
			self._reconcileScheduled = false
			self._reconcile()
		}
	}

	private func _reconcile() {
		guard _featureEnabled else {
			_endCurrentActivity(reason: "background audio turned off")
			return
		}

		// No owners + no running audio means BackgroundAudioManager has completed
		// its own linger window. That is the authoritative end of this local job.
		if _activeOwners.isEmpty && !_audioIsRunning {
			_handoffOwners = []
			_focusOwner = nil
			_endCurrentActivity(reason: "work finished")
			return
		}

		guard let state = _currentState() else { return }
		guard !_suppressedForCurrentWork else { return }

		if _activity == nil {
			_desiredState = state
			// Never create a brand-new activity for a job that already released
			// its owner and is only inside the audio manager's linger/handoff window.
			if !_activeOwners.isEmpty {
				_startIfPossible(with: state)
			}
			return
		}

		_enqueue(state)
	}

	// MARK: - Activity start/update/end

	private func _startIfPossible(with state: KeepAliveAttributes.ContentState) {
		guard _activity == nil,
		      _appIsActive,
		      !_activeOwners.isEmpty,
		      !_suppressedForCurrentWork,
		      Date() >= _nextStartAttempt else { return }

		guard ActivityAuthorizationInfo().areActivitiesEnabled else {
			_nextStartAttempt = Date().addingTimeInterval(Self._retryDelay)
			Logger.misc.error("Live Activities are disabled for this app.")
			BackgroundAudioStatus.shared.record(.island, "can't show — Live Activities are turned off for Ksign")
			return
		}

		do {
			let activity = try Activity.request(
				attributes: KeepAliveAttributes(startedAt: Date()),
				content: ActivityContent(state: state, staleDate: nil),
				pushType: nil
			)

			_activity = activity
			_lastDeliveredState = state
			_nextStartAttempt = .distantPast
			if _desiredState == state { _desiredState = nil }

			BackgroundAudioStatus.shared.record(.island, "showing — \(state.summaryLine)")
			_watchActivityState(activity)
			_drainUpdates()
		} catch {
			_nextStartAttempt = Date().addingTimeInterval(Self._retryDelay)
			Logger.misc.error("Keep-alive Live Activity failed to start: \(error.localizedDescription)")
			BackgroundAudioStatus.shared.record(.island, "failed to start — \(error.localizedDescription)")
		}
	}

	private func _enqueue(_ state: KeepAliveAttributes.ContentState) {
		guard state != _lastDeliveredState || _desiredState != nil else { return }
		_desiredState = state
		_drainUpdates()
	}

	private func _drainUpdates() {
		guard !_updateInFlight,
		      let activity = _activity,
		      let state = _desiredState else { return }

		if state == _lastDeliveredState {
			_desiredState = nil
			return
		}

		_desiredState = nil
		_updateInFlight = true
		_inFlightState = state
		let activityID = activity.id

		Task(priority: .userInitiated) { [weak self] in
			await activity.update(ActivityContent(state: state, staleDate: nil))

			self?._queue.async {
				self?._finishUpdate(activityID: activityID, state: state)
			}
		}
	}

	private func _finishUpdate(
		activityID: String,
		state: KeepAliveAttributes.ContentState
	) {
		_updateInFlight = false
		_inFlightState = nil

		guard _activity?.id == activityID else {
			_drainUpdates()
			return
		}

		_lastDeliveredState = state

		let count = "\(state.completed.map(String.init) ?? "–")/\(state.total.map(String.init) ?? "–")"
		let percent = state.progressFraction
			.map { " · \(Int(($0 * 100).rounded()))%" }
			?? ""
		BackgroundAudioStatus.shared.record(
			.island,
			"updated — \(count)\(percent) — \(state.summaryLine)"
		)

		_drainUpdates()
	}

	private func _endCurrentActivity(reason: String) {
		let finalState = _desiredState ?? _inFlightState ?? _lastDeliveredState
		_desiredState = nil
		_updateInFlight = false
		_inFlightState = nil
		_handoffOwners = []
		_focusOwner = nil
		_nextStartAttempt = .distantPast

		guard let activity = _activity else {
			_lastDeliveredState = nil
			return
		}

		_activity = nil
		_lastDeliveredState = nil

		BackgroundAudioStatus.shared.record(.island, "ended — \(reason)")

		Task(priority: .utility) {
			let finalContent = finalState.map {
				ActivityContent(state: $0, staleDate: nil)
			}
			await activity.end(finalContent, dismissalPolicy: .immediate)
		}
	}

	private func _watchActivityState(_ activity: Activity<KeepAliveAttributes>) {
		let id = activity.id

		Task(priority: .utility) { [weak self] in
			for await state in activity.activityStateUpdates {
				self?._queue.async {
					guard let self, self._activity?.id == id else { return }

					if state == .stale {
						BackgroundAudioStatus.shared.record(.island, "system marked activity stale")
						return
					}

					guard state == .ended || state == .dismissed else { return }

					self._activity = nil
					self._desiredState = nil
					self._updateInFlight = false
					self._inFlightState = nil
					self._lastDeliveredState = nil
					self._suppressedForCurrentWork = true
					BackgroundAudioStatus.shared.record(
						.island,
						state == .dismissed ? "activity dismissed" : "system ended activity"
					)
				}

				if state == .ended || state == .dismissed { break }
			}
		}
	}

	// MARK: - Work reports

	// Preferred path for reporters that already know their complete state. Updating
	// all fields in one queue transaction prevents ActivityKit from ever seeing a
	// half-updated snapshot such as a new count paired with an old percentage.
	func report(
		_ owner: BackgroundAudioManager.Owner,
		completed: Int?,
		total: Int?,
		fraction: Double?,
		detail: String?
	) {
		_merge(owner) { report in
			if let total, total > 0, let completed {
				report.completed = max(0, min(completed, total))
				report.total = total
			} else {
				report.completed = nil
				report.total = nil
			}

			report.fraction = Self._quantizedFraction(fraction)

			let normalized = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
			let value = (normalized?.isEmpty == false) ? normalized : nil
			if report.detail != value {
				report.detail = value
				report.detailStartedAt = value == nil ? nil : Date()
			}
		}
	}

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

	func report(_ owner: BackgroundAudioManager.Owner, fraction: Double?) {
		_merge(owner) {
			$0.fraction = Self._quantizedFraction(fraction)
		}
	}

	private static func _quantizedFraction(_ fraction: Double?) -> Double? {
		guard let fraction else { return nil }
		let clamped = min(1, max(0, fraction))
		guard clamped < 1 else { return 1 }

		let units = floor((clamped + 0.000_000_001) / _progressStep)
		return min(0.99, units * _progressStep)
	}

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

	private func _merge(
		_ owner: BackgroundAudioManager.Owner,
		_ change: @escaping (inout _Report) -> Void
	) {
		let key = owner.displayName

		_queue.async {
			var report = self._reports[key] ?? _Report()
			let before = report
			change(&report)

			guard report != before else { return }

			let removed = report == _Report()
			if removed {
				self._reports.removeValue(forKey: key)
				self._reportSeq.removeValue(forKey: key)
				if self._focusOwner == key { self._focusOwner = nil }
			} else {
				self._reports[key] = report
				self._sequence += 1
				self._reportSeq[key] = self._sequence
			}

			// A reporter commonly clears itself just after its audio owner releases.
			// Don't erase the terminal state from the Live Activity during the handoff
			// audio-manager linger; the final content remains what was last delivered.
			if removed && !self._activeOwners.contains(key) { return }
			self._scheduleReconcile()
		}
	}
}

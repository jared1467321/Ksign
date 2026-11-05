//
//  ExtractManager.swift
//  Asign
//
//  Created by Nagata Asami on 3/10/25.
//

import Foundation
import Combine

final class ExtractItem: ObservableObject, Identifiable {
	@Published var progress: Double = 0.0
	let id: String
	let fileName: String
    private var presentation: ForegroundValueDelivery<Double>!
    private let presentationLock = NSLock()
    private var acceptsProgress = true
    func report(_ progress: Double) {
        presentationLock.lock()
        if acceptsProgress { presentation.submit(progress) }
        presentationLock.unlock()
    }
    func stopPresentation() {
        presentationLock.lock()
        acceptsProgress = false
        presentation.cancel()
        presentationLock.unlock()
    }

	init(id: String = UUID().uuidString, fileName: String) {
		self.id = id
		self.fileName = fileName
        presentation = ForegroundValueDelivery { [weak self] value in
            if self?.progress != value { self?.progress = value }
        }
	}
}

final class ExtractManager: ObservableObject {
	static let shared = ExtractManager()

	@Published var extractItems: [ExtractItem] = []

	// Live Activity state is independent from the SwiftUI list and lives on its
	// own serial queue. Completion can therefore be published from the extraction
	// worker before any MainActor/UI work is scheduled.
	private let _activityQueue = DispatchQueue(
		label: "nya.asami.asign.extract-live-activity",
		qos: .userInitiated
	)
	private var _activityItemIDs: Set<String> = []
	private var _activeActivityItemIDs: Set<String> = []
	private var _completedActivityItemIDs: Set<String> = []
	private var _failedActivityItemIDs: Set<String> = []
	private var _activityProgress: [String: Double] = [:]
	private var _activityNames: [String: String] = [:]
	private var _activityLastTouched: [String: Int] = [:]
	private var _activitySequence = 0

    private let progressLock = NSLock()
    private var pendingProgress: [String: Double] = [:]
    private var progressDelivery: LatestValueDelivery<[String: Double]>!

    private init() {
        progressDelivery = LatestValueDelivery(queue: _activityQueue) { [weak self] updates in
            guard let self else { return }
            var changed = false
            for (id, value) in updates where self._activeActivityItemIDs.contains(id) {
                guard self._activityProgress[id] != value else { continue }
                self._activityProgress[id] = value
                self._activitySequence += 1
                self._activityLastTouched[id] = self._activitySequence
                changed = true
            }
            if changed { self._publishActivity() }
        }
    }

	@discardableResult
	func start(fileName: String) -> ExtractItem {
		let item = ExtractItem(fileName: fileName)
		// Submit while this foreground/user-initiated start call is still active;
		// the main-queue list mutation below remains the UI source of truth.
		BackgroundTaskManager.shared.claim(.extracting)
        _startActivity(id: item.id, fileName: fileName)

		DispatchQueue.main.async {
			self.extractItems.append(item)
		}
		return item
	}

	func updateProgress(for item: ExtractItem, progress: Double) {
		let clamped = max(0.0, min(1.0, progress))

        progressLock.lock()
        pendingProgress[item.id] = clamped
        let snapshot = pendingProgress
        progressDelivery.submit(snapshot)
        progressLock.unlock()

        item.report(clamped)
	}

	func finish(item: ExtractItem, succeeded: Bool = true) {
        item.stopPresentation()
        progressLock.lock()
        pendingProgress.removeValue(forKey: item.id)
        progressLock.unlock()
		_finishActivity(id: item.id, succeeded: succeeded)

		DispatchQueue.main.async {
			if let idx = self.extractItems.firstIndex(where: { $0.id == item.id }) {
				self.extractItems.remove(at: idx)
			}
		}
	}

	private func _startActivity(id: String, fileName: String) {
		_activityQueue.async { [self] in
			if _activeActivityItemIDs.isEmpty {
				_activityItemIDs.removeAll()
				_completedActivityItemIDs.removeAll()
				_failedActivityItemIDs.removeAll()
				_activityProgress.removeAll()
				_activityNames.removeAll()
				_activityLastTouched.removeAll()
				_activitySequence = 0
				BackgroundTaskManager.shared.clearReport(.extracting)
			}

			_activityItemIDs.insert(id)
			_activeActivityItemIDs.insert(id)
			_activityProgress[id] = 0
			_activityNames[id] = fileName
			_activitySequence += 1
			_activityLastTouched[id] = _activitySequence
            BackgroundTaskManager.shared.claim(.extracting)
			_publishActivity()
		}
	}

	private func _finishActivity(id: String, succeeded: Bool) {
		_activityQueue.async { [self] in
			guard _activityItemIDs.contains(id) else { return }
			_activeActivityItemIDs.remove(id)
			if succeeded {
				_completedActivityItemIDs.insert(id)
				_failedActivityItemIDs.remove(id)
				_activityProgress[id] = 1
			} else {
				_failedActivityItemIDs.insert(id)
				_completedActivityItemIDs.remove(id)
				// A failed item is still terminal work for aggregate progress.
				_activityProgress[id] = 1
			}
			_activitySequence += 1
			_activityLastTouched[id] = _activitySequence
			_publishActivity()
            if _activeActivityItemIDs.isEmpty {
                BackgroundTaskManager.shared.release(.extracting, success: _failedActivityItemIDs.isEmpty)
            }
		}
	}

	private func _publishActivity() {
		guard !_activityItemIDs.isEmpty else { return }
		let completed = _completedActivityItemIDs.intersection(_activityItemIDs).count
		let failed = _failedActivityItemIDs.intersection(_activityItemIDs).count
		let total = _activityItemIDs.count
		let terminal = completed + failed
		let aggregateFraction = min(
			1,
			max(
				0,
				_activityItemIDs.reduce(0.0) { partial, id in
					partial + (_activityProgress[id] ?? 0)
				} / Double(total)
			)
		)

		let currentID = _activeActivityItemIDs.max(by: {
			(_activityLastTouched[$0] ?? 0) < (_activityLastTouched[$1] ?? 0)
		}) ?? _activityItemIDs.max(by: {
			(_activityLastTouched[$0] ?? 0) < (_activityLastTouched[$1] ?? 0)
		})

		BackgroundTaskManager.shared.report(
			.extracting,
			completed: terminal,
			total: total,
			fraction: aggregateFraction,
			detail: terminal == total ? (failed == 0 ? "Completed" : "Error") : "Extracting",
			currentItem: currentID.flatMap { _activityNames[$0] }
		)
	}

}

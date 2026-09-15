//
//  ExtractManager.swift
//  Ksign
//
//  Created by Nagata Asami on 3/10/25.
//

import Foundation
import Combine

final class ExtractItem: ObservableObject, Identifiable {
	@Published var progress: Double = 0.0
	let id: String
	let fileName: String

	init(id: String = UUID().uuidString, fileName: String) {
		self.id = id
		self.fileName = fileName
	}
}

final class ExtractManager: ObservableObject {
	static let shared = ExtractManager()

	@Published var extractItems: [ExtractItem] = []

	// Live Activity state is independent from the SwiftUI list and lives on its
	// own serial queue. Completion can therefore be published from the extraction
	// worker before any MainActor/UI work is scheduled.
	private let _activityQueue = DispatchQueue(
		label: "nya.asami.ksign.extract-live-activity",
		qos: .userInitiated
	)
	private var _activityItemIDs: Set<String> = []
	private var _activeActivityItemIDs: Set<String> = []
	private var _completedActivityItemIDs: Set<String> = []
	private var _failedActivityItemIDs: Set<String> = []

	private init() { }

	@discardableResult
	func start(fileName: String) -> ExtractItem {
		let item = ExtractItem(fileName: fileName)
		_startActivity(id: item.id)

		DispatchQueue.main.async {
			self.extractItems.append(item)
			self._updateBackgroundAudioState()
		}
		return item
	}

	func updateProgress(for item: ExtractItem, progress: Double) {
		let clamped = max(0.0, min(1.0, progress))
		DispatchQueue.main.async {
			item.progress = clamped
		}
	}

	func finish(item: ExtractItem, succeeded: Bool = true) {
		_finishActivity(id: item.id, succeeded: succeeded)

		DispatchQueue.main.async {
			if let idx = self.extractItems.firstIndex(where: { $0.id == item.id }) {
				self.extractItems.remove(at: idx)
			}
			self._updateBackgroundAudioState()
		}
	}

	private func _startActivity(id: String) {
		_activityQueue.sync {
			if _activeActivityItemIDs.isEmpty {
				_activityItemIDs.removeAll()
				_completedActivityItemIDs.removeAll()
				_failedActivityItemIDs.removeAll()
				if #available(iOS 16.2, *) {
					KeepAliveActivityController.shared.clearReport(.extracting)
				}
			}

			_activityItemIDs.insert(id)
			_activeActivityItemIDs.insert(id)
			_publishActivity()
		}
	}

	private func _finishActivity(id: String, succeeded: Bool) {
		_activityQueue.sync {
			guard _activityItemIDs.contains(id) else { return }
			_activeActivityItemIDs.remove(id)
			if succeeded {
				_completedActivityItemIDs.insert(id)
				_failedActivityItemIDs.remove(id)
			} else {
				_failedActivityItemIDs.insert(id)
				_completedActivityItemIDs.remove(id)
			}
			_publishActivity()
		}
	}

	private func _publishActivity() {
		guard #available(iOS 16.2, *), !_activityItemIDs.isEmpty else { return }
		let completed = _completedActivityItemIDs.intersection(_activityItemIDs).count
		let failed = _failedActivityItemIDs.intersection(_activityItemIDs).count
		let total = _activityItemIDs.count
		let terminal = completed + failed

		KeepAliveActivityController.shared.report(.extracting, completed: completed, total: total)
		KeepAliveActivityController.shared.report(.extracting, fraction: nil)
		KeepAliveActivityController.shared.report(
			.extracting,
			detail: terminal == total ? (failed == 0 ? "Completed" : "Error") : "Extracting"
		)
	}

	// Identity-claimed off the live list, the same way `DownloadManager` does
	// it: the list is already the source of truth for whether anything is
	// extracting, so deriving the claim from it can't drift out of sync.
	private func _updateBackgroundAudioState() {
		if !extractItems.isEmpty {
			BackgroundAudioManager.shared.claim(.extracting)
		} else {
			BackgroundAudioManager.shared.release(.extracting)
		}
	}
}

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

	private init() { }

	@discardableResult
	func start(fileName: String) -> ExtractItem {
		let item = ExtractItem(fileName: fileName)
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

	func finish(item: ExtractItem) {
		DispatchQueue.main.async {
			if let idx = self.extractItems.firstIndex(where: { $0.id == item.id }) {
				self.extractItems.remove(at: idx)
			}
			self._updateBackgroundAudioState()
		}
	}

	// Identity-claimed off the live list, the same way `DownloadManager` does
	// it: the list is already the source of truth for whether anything is
	// extracting, so deriving the claim from it can't drift out of sync the way
	// a separately-maintained counter could.
	//
	// Only ever called from the main queue, inside the same async block that
	// mutated the list, so it never reads a half-applied state.
	private func _updateBackgroundAudioState() {
		if !extractItems.isEmpty {
			BackgroundAudioManager.shared.claim(.extracting)
		} else {
			BackgroundAudioManager.shared.release(.extracting)
		}
	}
}



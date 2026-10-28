//
//  LogsManager.swift
//  Asign
//
//  Created by Nagata Asami on 8/10/25.
//

import Foundation
import SwiftUI
import UIKit

final class LogsManager: ObservableObject {
	static let shared = LogsManager()

	@Published private(set) var entries: [LogEntry] = []
	private(set) var totalEntryCount = 0
	var hasOlderEntries: Bool { totalEntryCount > entries.count }
#if DEBUG
	@Published var isCapturing: Bool = false
#else
	@Published var isCapturing: Bool = true
#endif

	private var _stdoutPipe: Pipe?
	private var _savedStdout: Int32?
	private let _store = SessionLogStore(fileURL: FileManager.default
		.urls(for: .cachesDirectory, in: .userDomainMask)[0]
		.appendingPathComponent("AsignLogs/session.log"))
	private var _presentedRevision: UInt64 = 0

	// Full history stays on disk. Only a bounded recent tail reaches SwiftUI,
	// at most once every 0.2 seconds while active with a Logs screen presented.
	// One outstanding snapshot bounds work while the main queue is busy.
	private let _presentationLock = NSLock()
	private var _needsDelivery = false
	private var _isAppActive = false
	private var _presentationOwners: Set<UUID> = []
	private var _deliveryQueued = false
	private let _presentationInterval: TimeInterval = 0.2
	private var _lifecycleObservers: [NSObjectProtocol] = []

	private init() {
		let center = NotificationCenter.default

		_lifecycleObservers.append(center.addObserver(
			forName: UIApplication.willResignActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			self?._setAppActive(false)
		})

		_lifecycleObservers.append(center.addObserver(
			forName: UIApplication.didEnterBackgroundNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			self?._setAppActive(false)
		})

		_lifecycleObservers.append(center.addObserver(
			forName: UIApplication.didBecomeActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			self?._setAppActive(true)
		})

		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			self._setAppActive(UIApplication.shared.applicationState == .active)
		}
	}

	deinit {
		for observer in _lifecycleObservers {
			NotificationCenter.default.removeObserver(observer)
		}
	}

	func startCapture() {
		if _stdoutPipe != nil { return }
		let pipe = Pipe()
		let saved = dup(STDOUT_FILENO)
		guard saved >= 0 else { isCapturing = false; return }
		guard dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0 else {
			close(saved)
			isCapturing = false
			return
		}
		_savedStdout = saved
		_stdoutPipe = pipe
		isCapturing = true
		_setupReadHandler(for: pipe)
	}

	func stopCapture() {
		// Pausing must restore the real descriptor before removing the reader.
		// Otherwise later stdout writes still target a pipe nobody is draining.
		if let saved = _savedStdout {
			guard dup2(saved, STDOUT_FILENO) >= 0 else { return }
			close(saved)
			_savedStdout = nil
		}
		_stdoutPipe?.fileHandleForReading.readabilityHandler = nil

		_stdoutPipe = nil
		isCapturing = false
	}

	func clear() {
		_store.clear { [weak self] snapshot in
			DispatchQueue.main.async { [weak self] in self?._publish(snapshot) }
		}
	}

	func export() async throws -> URL {
		try await _store.export()
	}

	func setPresented(_ presented: Bool, owner: UUID) {
		_presentationLock.lock()
		if presented {
			_presentationOwners.insert(owner)
			_needsDelivery = true
		} else {
			_presentationOwners.remove(owner)
		}
		let shouldFlush = presented && _isAppActive && !_deliveryQueued
		if shouldFlush { _deliveryQueued = true }
		_presentationLock.unlock()
		if shouldFlush { _queuePresentationDelivery(after: 0) }
	}

	private func _setupReadHandler(for pipe: Pipe?) {
		guard let pipe else { return }
		pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
			guard let self else { return }

			let data = handle.availableData
			guard !data.isEmpty else { handle.readabilityHandler = nil; return }
			guard self._store.append(data) else { return }
			self._requestPresentation()
		}
	}

	private func _requestPresentation() {
		var shouldQueueDelivery = false

		_presentationLock.lock()
		_needsDelivery = true
		if _isAppActive && !_presentationOwners.isEmpty && !_deliveryQueued {
			_deliveryQueued = true
			shouldQueueDelivery = true
		}
		_presentationLock.unlock()

		if shouldQueueDelivery {
			_queuePresentationDelivery(after: _presentationInterval)
		}
	}

	private func _queuePresentationDelivery(after delay: TimeInterval) {
		DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
			self?._deliverPendingEntries()
		}
	}

	private func _deliverPendingEntries() {
		_presentationLock.lock()
		guard _isAppActive, !_presentationOwners.isEmpty else {
			_deliveryQueued = false
			_presentationLock.unlock()
			return
		}

		_needsDelivery = false
		_presentationLock.unlock()

		// Never wait for file I/O or an export on the main queue.
		_store.snapshot { [weak self] snapshot in
			DispatchQueue.main.async { [weak self] in self?._finishDelivery(snapshot) }
		}
	}

	private func _finishDelivery(_ snapshot: SessionLogStore.Snapshot) {
		_presentationLock.lock()
		let active = _isAppActive && !_presentationOwners.isEmpty
		if !active { _needsDelivery = true }
		let shouldQueueAgain = active && _needsDelivery
		_deliveryQueued = shouldQueueAgain
		_presentationLock.unlock()

		if active { _publish(snapshot) }
		if shouldQueueAgain {
			_queuePresentationDelivery(after: _presentationInterval)
		}
	}

	private func _publish(_ snapshot: SessionLogStore.Snapshot) {
		// A clear can overtake a queued presentation. Never resurrect an older
		// tail or erase newer post-clear lines with a stale clear callback.
		guard snapshot.revision > _presentedRevision else { return }
		_presentedRevision = snapshot.revision
		totalEntryCount = snapshot.totalEntryCount
		entries = snapshot.entries
	}

	private func _setAppActive(_ active: Bool) {
		var shouldFlush = false

		_presentationLock.lock()
		_isAppActive = active
		if active && !_presentationOwners.isEmpty && _needsDelivery && !_deliveryQueued {
			_deliveryQueued = true
			shouldFlush = true
		}
		_presentationLock.unlock()

		if shouldFlush {
			// Catch up to the bounded tail; full history remains in the session file.
			_queuePresentationDelivery(after: 0)
		}
	}
}

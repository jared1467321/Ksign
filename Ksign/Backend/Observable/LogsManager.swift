//
//  LogsManager.swift
//  Ksign
//
//  Created by Nagata Asami on 8/10/25.
//

import Foundation
import SwiftUI
import UIKit

final class LogsManager: ObservableObject {
	static let shared = LogsManager()

	@Published var entries: [LogEntry] = []
#if DEBUG
	@Published var isCapturing: Bool = false
#else
	@Published var isCapturing: Bool = true
#endif

	private var _stdoutPipe: Pipe?

	// stdout can be extremely chatty while zsign is working. Keep collecting every
	// line, but do not turn every pipe read into its own ObservableObject change.
	// While the app is active we publish one batch at most every 0.2 seconds;
	// while inactive/locked we retain the lines without publishing anything and
	// flush them when the app becomes active again.
	private let _presentationLock = NSLock()
	private var _pendingEntries: [LogEntry] = []
	private var _isAppActive = false
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
		isCapturing = true

		_stdoutPipe = Pipe()

		if let out = _stdoutPipe { _redirect(fd: STDOUT_FILENO, to: out) }

		_setupReadHandler(for: _stdoutPipe)
	}

	func stopCapture() {
		_stdoutPipe?.fileHandleForReading.readabilityHandler = nil

		_stdoutPipe = nil
		isCapturing = false
	}

	func clear() {
		_presentationLock.lock()
		_pendingEntries.removeAll(keepingCapacity: true)
		_presentationLock.unlock()

		DispatchQueue.main.async { self.entries.removeAll() }
	}

	func exportToText() -> String {
		let exportDateFormatter = DateFormatter()
		exportDateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
		let exportTimestamp = exportDateFormatter.string(from: Date())

		// Include the not-yet-published tail too, so throttling presentation never
		// makes an export silently omit the newest captured stdout lines.
		_presentationLock.lock()
		let pending = _pendingEntries
		_presentationLock.unlock()
		let allEntries = entries + pending

		var logText = "Ksign Logs Export\n"
		logText += "Exported: \(exportTimestamp)\n"
		logText += "Total entries: \(allEntries.count)\n"
		logText += String(repeating: "=", count: 30) + "\n\n"

		for entry in allEntries {
			logText += "\(entry.message)\n"
		}

		return logText
	}

	private func _redirect(fd: Int32, to pipe: Pipe) {
		let handle = pipe.fileHandleForWriting
		dup2(handle.fileDescriptor, fd)
	}

	private func _setupReadHandler(for pipe: Pipe?) {
		guard let pipe else { return }
		pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
			guard let self else { return }

			let data = handle.availableData
			guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

			let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
			guard !lines.isEmpty else { return }

			self._enqueueForPresentation(lines.map { LogEntry(message: $0) })
		}
	}

	private func _enqueueForPresentation(_ newEntries: [LogEntry]) {
		var shouldQueueDelivery = false

		_presentationLock.lock()
		_pendingEntries.append(contentsOf: newEntries)
		if _isAppActive && !_deliveryQueued {
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
		var batch: [LogEntry] = []

		_presentationLock.lock()
		guard _isAppActive else {
			_deliveryQueued = false
			_presentationLock.unlock()
			return
		}

		batch = _pendingEntries
		_pendingEntries.removeAll(keepingCapacity: true)
		_deliveryQueued = false
		_presentationLock.unlock()

		if !batch.isEmpty {
			entries.append(contentsOf: batch)
		}

		var shouldQueueAgain = false
		_presentationLock.lock()
		if _isAppActive && !_pendingEntries.isEmpty && !_deliveryQueued {
			_deliveryQueued = true
			shouldQueueAgain = true
		}
		_presentationLock.unlock()

		if shouldQueueAgain {
			_queuePresentationDelivery(after: _presentationInterval)
		}
	}

	private func _setAppActive(_ active: Bool) {
		var shouldFlush = false

		_presentationLock.lock()
		_isAppActive = active
		if active && !_pendingEntries.isEmpty && !_deliveryQueued {
			_deliveryQueued = true
			shouldFlush = true
		}
		_presentationLock.unlock()

		if shouldFlush {
			// A foreground transition should immediately catch the log UI up to the
			// latest retained batch; normal active capture then resumes at 5 Hz.
			_queuePresentationDelivery(after: 0)
		}
	}
}

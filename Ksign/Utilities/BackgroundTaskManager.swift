//
//  BackgroundTaskManager.swift
//  Feather
//
//  Created by Nagata Asami on 4/1/26.
//

import Foundation
import BackgroundTasks
import CryptoKit

@available(iOS 26.0, *)
final class BackgroundTaskManager: ObservableObject {
    static let shared = BackgroundTaskManager()

    private let baseId = "\(Bundle.main.bundleIdentifier!).userTask"

    // Everything below the lock used to be a plain Dictionary/Set mutated from
    // two different execution contexts with no synchronization:
    //   - the main thread, via `updateProgress` / `stopTask` (called out of the
    //     extraction progress callback's `DispatchQueue.main.async`), and
    //   - BGTaskScheduler's own queue, via the `register` completion handler and
    //     each task's `expirationHandler`.
    // Concurrent unsynchronized access to a Swift Dictionary is undefined
    // behavior — it can corrupt, crash, or spin. Every touch of these two
    // collections now goes through `_lock`, and the lock is only ever held
    // around the collection access itself, never across a BGTaskScheduler or
    // BGContinuedProcessingTask call (holding a lock across framework calls is
    // how you trade one hang for another).
    private let _lock = NSLock()
    private var _activeTasks: [String: BGContinuedProcessingTask] = [:]
    private var _registeredTasks: Set<String> = []

    // MARK: - Locked accessors

    private func _task(for id: String) -> BGContinuedProcessingTask? {
        _lock.lock(); defer { _lock.unlock() }
        return _activeTasks[id]
    }

    private func _store(_ task: BGContinuedProcessingTask, for id: String) {
        _lock.lock(); defer { _lock.unlock() }
        _activeTasks[id] = task
    }

    // Remove-and-return in one locked step. This is what makes completion safe:
    // if a 100% progress update and the expiration handler (or a download-side
    // stopTask) race to finish the same task, exactly one of them gets the task
    // back and calls `setTaskCompleted`; the loser gets nil and does nothing.
    // The old code could call `setTaskCompleted` twice on the same task.
    private func _take(for id: String) -> BGContinuedProcessingTask? {
        _lock.lock(); defer { _lock.unlock() }
        return _activeTasks.removeValue(forKey: id)
    }

    private func _isRegistered(_ id: String) -> Bool {
        _lock.lock(); defer { _lock.unlock() }
        return _registeredTasks.contains(id)
    }

    private func _markRegistered(_ id: String) {
        _lock.lock(); defer { _lock.unlock() }
        _registeredTasks.insert(id)
    }

    // MARK: - Public API (unchanged signatures)

    func startTask(for downloadId: String, filename: String) {
        let taskIdentifier = "\(baseId).\(downloadId.md5)"

        if !_isRegistered(taskIdentifier) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { [weak self] task in
                guard let self, let task = task as? BGContinuedProcessingTask else { return }
                self._store(task, for: task.identifier)

                task.expirationHandler = { [weak self] in
                    guard let self else { return }
                    if let download = DownloadManager.shared.getDownload(by: downloadId) {
                        DownloadManager.shared.cancelDownload(download)
                    }
                    // Pull it out so a later stopTask can't double-complete it.
                    _ = self._take(for: task.identifier)
                }
            }
            _markRegistered(taskIdentifier)
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: taskIdentifier,
            title: filename,
            subtitle: .localized("Downloading")
        )
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print(error)
        }
    }

    func updateProgress(for downloadId: String, progress: Double) {
        let taskIdentifier = "\(baseId).\(downloadId.md5)"
        guard let task = _task(for: taskIdentifier) else { return }

        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = Int64(progress * 100)
        task.updateTitle(task.title, subtitle: "\(Int(progress * 100))%")

        if task.progress.completedUnitCount >= task.progress.totalUnitCount {
            stopTask(for: downloadId, success: true)
        }
    }

    func stopTask(for downloadId: String, success: Bool) {
        let taskIdentifier = "\(baseId).\(downloadId.md5)"
        // Atomic take: only the caller that actually removes the task completes
        // it. Framework call happens outside the lock.
        guard let task = _take(for: taskIdentifier) else { return }
        task.setTaskCompleted(success: success)
    }
}

extension String {
    var md5: String {
        Insecure.MD5.hash(data: Data(self.utf8)).map { String(format: "%02hhx", $0) }.joined()
    }
}

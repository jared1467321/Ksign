//
//  enum.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//

import Foundation
import Combine
import UIKit.UIImpactFeedbackGenerator
import SwiftUI // For ByteCountFormatter
import UserNotifications

// Import the error handlers module
@_exported import class UIKit.UIImpactFeedbackGenerator

class Download: Identifiable, @unchecked Sendable, ObservableObject {
	@Published var progress: Double = 0.0
	@Published var bytesDownloaded: Int64 = 0
	@Published var totalBytes: Int64 = 0
	@Published var unpackageProgress: Double = 0.0
	
	var overallProgress: Double {
		onlyArchiving
		? unpackageProgress
		: (0.3 * unpackageProgress) + (0.7 * progress)
	}

	var formattedFileSize: String {
		return totalBytes.formattedByteCount
	}
	
	var progressText: String {
		if unpackageProgress > 0 {
			return "\(Int(unpackageProgress * 100))%"
		}
		let downloadedStr = bytesDownloaded.formattedByteCount
		let totalStr = totalBytes.formattedByteCount
		return "\(downloadedStr) / \(totalStr) (\(Int(progress * 100))%)"
	}
    var task: URLSessionDownloadTask?
    var resumeData: Data?
	
	let id: String
	let url: URL
	let fileName: String
	let onlyArchiving: Bool
    
    init(
		id: String,
		url: URL,
		onlyArchiving: Bool = false
	) {
		self.id = id
        self.url = url
		self.onlyArchiving = onlyArchiving
        self.fileName = url.lastPathComponent
    }
}

class DownloadManager: NSObject, ObservableObject {
	static let shared = DownloadManager()
	
    @Published var downloads: [Download] = []
	
	var manualDownloads: [Download] {
		downloads.filter { isManualDownload($0.id) }
	}

	// MARK: - Bulk import backlog
	//
	// A `Download` only exists once an import has actually started, and the
	// bulk importer deliberately runs two at a time so a big batch doesn't
	// kick off thirty-five extractions at once. That's why the header's "+N"
	// was pinned at "+1": it was counting work in flight, not work left.
	//
	// This is the rest of the batch — selected, but not yet handed a
	// `Download`. Batches are tracked by token rather than as one running
	// total so that starting a second import while the first is still going
	// can't leave a phantom count behind.
	@Published private(set) var queuedImportCount: Int = 0

	private var _importBatches: [UUID: Int] = [:]

	// Live Activity progress is intentionally mirrored by a worker-safe
	// reporter below. The UI backlog remains MainActor-owned, while the pill's
	// completion events do not depend on MainActor being scheduled in background.

	@MainActor
	func beginImportBatch(count: Int) -> UUID {
		let token = UUID()
		if count > 0 {
			_importBatches[token] = count
			ImportLiveActivityReporter.shared.begin(token: token, total: count)
		}
		_recomputeQueuedImports()
		return token
	}

	// Called the moment an item is dequeued and given a real `Download`, so
	// it moves from "waiting" to "in flight" without ever being counted twice.
	@MainActor
	func importDidStart(_ token: UUID) {
		guard let remaining = _importBatches[token] else { return }
		if remaining <= 1 {
			_importBatches[token] = nil
		} else {
			_importBatches[token] = remaining - 1
		}
		_recomputeQueuedImports()
	}

	// Safety net for cancellation / early termination. The reporter turns any
	// unaccounted items into failures and leaves the final n/total state visible
	// until the system continued-processing task completes.
	@MainActor
	func endImportBatch(_ token: UUID) {
		_importBatches.removeValue(forKey: token)
		_recomputeQueuedImports()
		ImportLiveActivityReporter.shared.end(token: token)
	}

	@MainActor
	private func _recomputeQueuedImports() {
		queuedImportCount = _importBatches.values.reduce(0, +)
	}

	// MARK: - Import-in-progress flag
	//
	// The Downloads screen refreshes its finished list whenever `downloads.count`
	// changes, so a newly finished *download* shows up. But importing also adds
	// and removes entries in this same `downloads` array, so every imported app
	// was triggering that refresh — a full disk rescan and reorder of the list,
	// per app. That's the "jumping around while importing", and the repeated
	// main-thread rescans are what stalled the app long enough for the watchdog
	// to kill it during a bulk import.
	//
	// Importing shouldn't touch that list at all. The view checks `isImporting`
	// and skips its refresh while this is set. It's a depth counter, not a bool,
	// so overlapping imports (or a bulk batch) can't clear it early.
	//
	// @Published so the Downloads screen can *structurally* branch on it, not
	// just consult it inside a callback. While a batch import runs, that screen
	// swaps its live per-app "Downloading" section for a single static row.
	@Published private var _importDepth = 0
	var isImporting: Bool { _importDepth > 0 }

	@MainActor func beginImport() {
		_importDepth += 1
	}

	@MainActor func endImport() {
		_importDepth = max(0, _importDepth - 1)
	}
	
    private var _session: URLSession!
    
    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        _session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    
    func startDownload(
		from url: URL,
		id: String = UUID().uuidString
	) -> Download {
        if let existingDownload = downloads.first(where: { $0.url == url }) {
            resumeDownload(existingDownload)
            return existingDownload
        }
        print(id)
		let download = Download(id: id, url: url)
        
        let task = _session.downloadTask(with: url)
        download.task = task
        task.resume()
        
        downloads.append(download)
		BackgroundTaskManager.shared.startTask(for: id, filename: url.lastPathComponent)
        return download
    }
	
	func startArchive(
		from url: URL,
		id: String = UUID().uuidString
	) -> Download {
		let download = Download(id: id, url: url, onlyArchiving: true)
		downloads.append(download)
		return download
	}
    
    func resumeDownload(_ download: Download) {
        if let resumeData = download.resumeData {
            let task = _session.downloadTask(withResumeData: resumeData)
            download.task = task
            task.resume()
            BackgroundTaskManager.shared.startTask(for: download.id, filename: download.fileName)
        } else if let url = download.task?.originalRequest?.url {
            let task = _session.downloadTask(with: url)
            download.task = task
            task.resume()
            BackgroundTaskManager.shared.startTask(for: download.id, filename: download.fileName)
        }
    }
    
    func cancelDownload(_ download: Download) {
        download.task?.cancel()
        BackgroundTaskManager.shared.stopTask(for: download.id, success: false)

        if let index = downloads.firstIndex(where: { $0.id == download.id }) {
            downloads.remove(at: index)
        }
    }
    
	func isManualDownload(_ string: String) -> Bool {
		return string.contains("FeatherManualDownload")
	}
	
	func getDownload(by id: String) -> Download? {
		return downloads.first(where: { $0.id == id })
	}
	
	func getDownloadIndex(by id: String) -> Int? {
		return downloads.firstIndex(where: { $0.id == id })
	}
	
	func getDownloadTask(by task: URLSessionDownloadTask) -> Download? {
		return downloads.first(where: { $0.task == task })
	}
}

extension DownloadManager: URLSessionDownloadDelegate {
	
	func handlePachageFile(
		url: URL,
		dl: Download?,
		liveActivityBatchToken: UUID? = nil,
		backgroundCompletion: ((Error?) -> Void)? = nil,
		completion: @escaping (Error?) -> Void
	) {
		// Local/direct imports use one aggregate continued-processing task. A
		// network download already owns a per-download continued-processing task
		// through extraction/import, so don't create a second system Live Activity
		// for the same work.
		let tracksImportWorkflow = dl == nil || dl?.onlyArchiving == true
		let standaloneToken = tracksImportWorkflow && liveActivityBatchToken == nil ? UUID() : nil
		let activityToken = tracksImportWorkflow ? (liveActivityBatchToken ?? standaloneToken) : nil
		if let standaloneToken {
			ImportLiveActivityReporter.shared.begin(token: standaloneToken, total: 1)
		}

		FR.handlePackageFile(
			url,
			download: dl,
			trackLiveActivity: false,
			backgroundCompletion: { err in
				if let dl, !dl.onlyArchiving {
					BackgroundTaskManager.shared.stopTask(for: dl.id, success: err == nil)
				}
				if let activityToken {
					ImportLiveActivityReporter.shared.finishItem(
						token: activityToken,
						succeeded: err == nil
					)
				}
				if let standaloneToken {
					ImportLiveActivityReporter.shared.end(token: standaloneToken)
				}
				backgroundCompletion?(err)
			}
		) { err in
			if let error = err {
				let generator = UINotificationFeedbackGenerator()
				generator.notificationOccurred(.error)
				print("Package handling error: \(error.localizedDescription)")
				if let nsError = error as? NSError {
					if nsError.domain == NSPOSIXErrorDomain && nsError.code == 28 {
						print("No space left on device")
					} else if nsError.domain == NSCocoaErrorDomain {
						print("Cocoa error: \(nsError.localizedDescription)")
					}
				}
				let errorString = String(describing: error)
				if errorString.contains("notEnoughDiskSpace") {
					print("Not enough disk space for extraction")
				} else if errorString.contains("payloadNotFound") {
					print("Payload folder not found in archive")
				}
			}
			DispatchQueue.main.async {
				if let dl = dl, let index = DownloadManager.shared.getDownloadIndex(by: dl.id) {
					DownloadManager.shared.downloads.remove(at: index)
				}
				if err == nil {
					self._notifyDownloadCompleted(fileName: url.lastPathComponent)
					self._removeStagedDownload(at: url)
				}
				completion(err)
			}
		}
	}

	func handlePachageFile(
		url: URL,
		dl: Download?,
		liveActivityBatchToken: UUID? = nil
	) async throws {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			self.handlePachageFile(
				url: url,
				dl: dl,
				liveActivityBatchToken: liveActivityBatchToken,
				backgroundCompletion: { err in
					if let error = err {
						continuation.resume(throwing: error)
					} else {
						continuation.resume()
					}
				},
				completion: { _ in }
			)
		}
	}
	
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		guard let download = getDownloadTask(by: downloadTask) else { return }
		
		var downloadDir: URL
		if !OptionsManager.shared.options.saveAppStoreDownloadsToDownloadsFolder {
			let tempDirectory = FileManager.default.temporaryDirectory
			downloadDir = tempDirectory.appendingPathComponent("FeatherDownloads", isDirectory: true)
		} else {
			downloadDir = URL.documentsDirectory.appendingPathComponent("Downloads")
		}
		
		do {
			try FileManager.default.createDirectoryIfNeeded(at: downloadDir)
			let suggestedFileName = downloadTask.response?.suggestedFilename ?? download.fileName
			let destinationURL = downloadDir.appendingPathComponent(suggestedFileName)
			try FileManager.default.removeFileIfNeeded(at: destinationURL)
			try FileManager.default.moveItem(at: location, to: destinationURL)
			self.handlePachageFile(url: destinationURL, dl: download) { err in
				if let error = err {
					print("Error handling downloaded file: \(error.localizedDescription)")
				}
			}
		} catch {
			print("Error handling downloaded file: \(error.localizedDescription)")
			BackgroundTaskManager.shared.stopTask(for: download.id, success: false)
			DispatchQueue.main.async {
				if let index = self.getDownloadIndex(by: download.id) {
					self.downloads.remove(at: index)
				}
			}
		}
	}
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let download = getDownloadTask(by: downloadTask) else { return }
        
        DispatchQueue.main.async {
            download.progress = totalBytesExpectedToWrite > 0
			? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
			: 0
            download.bytesDownloaded = totalBytesWritten
            download.totalBytes = totalBytesExpectedToWrite
            BackgroundTaskManager.shared.updateProgress(for: download.id, progress: download.overallProgress)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard
			let _ = error,
			let downloadTask = task as? URLSessionDownloadTask,
			let download = getDownloadTask(by: downloadTask)
		else {
			return
		}
		
		BackgroundTaskManager.shared.stopTask(for: download.id, success: false)
		DispatchQueue.main.async {
			if let index = self.getDownloadIndex(by: download.id) {
				self.downloads.remove(at: index)
			}
		}
    }
    
    
    // The .ipa has been extracted into Documents by this point, so the archive
    // itself is redundant — but only when it's ours to delete. If the user
    // asked for downloads to be kept, it's sitting in Documents/Downloads
    // deliberately and must stay. Anything else lives in tmp, which was only
    // ever swept at app launch, so a long session held on to every archive it
    // had downloaded.
    private func _removeStagedDownload(at url: URL) {
        guard !OptionsManager.shared.options.saveAppStoreDownloadsToDownloadsFolder else { return }

        // Belt and braces: only ever touch our own staging directory, never a
        // file the user handed us from elsewhere.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeatherDownloads", isDirectory: true)

        guard url.path.hasPrefix(staging.path) else { return }

        try? FileManager.default.removeItem(at: url)
    }

    private func _notifyDownloadCompleted(fileName: String) {
        guard OptionsManager.shared.options.notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = String.localized("Download Completed")
        content.body = fileName
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "download.\(fileName)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("Failed to schedule notification: \(error.localizedDescription)") }
        }
    }
}


// MARK: - Simple, background-safe import Live Activity progress

// One stable denominator and one explicit terminal event per IPA. This mirrors
// the IPA Vault model: no queue-depth arithmetic, no extraction percentage spam,
// and no dependency on MainActor callbacks while the app is backgrounded.
final class ImportLiveActivityReporter {
	static let shared = ImportLiveActivityReporter()

	private struct Batch {
		var total: Int
		var completed = 0
		var failed = 0

		var terminal: Int { completed + failed }
	}

	private let queue = DispatchQueue(
		label: "nya.asami.ksign.import-live-activity",
		qos: .userInitiated
	)
	private var batches: [UUID: Batch] = [:]
	private var activeTokens: Set<UUID> = []

	private init() { }

	func begin(token: UUID, total: Int) {
		guard total > 0 else { return }
		queue.sync {
			if self.activeTokens.isEmpty {
				self.batches.removeAll()
				BackgroundTaskManager.shared.clearReport(.importing)
				BackgroundTaskManager.shared.claim(.importing)
			}

			self.activeTokens.insert(token)
			self.batches[token] = Batch(total: total)
			self.publish()
		}
	}

	func finishItem(token: UUID, succeeded: Bool) {
		queue.async {
			guard var batch = self.batches[token], batch.terminal < batch.total else { return }
			if succeeded {
				batch.completed += 1
			} else {
				batch.failed += 1
			}
			self.batches[token] = batch
			self.publish()
		}
	}

	func end(token: UUID) {
		queue.async {
			if var batch = self.batches[token], batch.terminal < batch.total {
				batch.failed += batch.total - batch.terminal
				self.batches[token] = batch
			}
			self.activeTokens.remove(token)
			self.publish()

			// The batch token holds one identity claim across gaps between individual
			// import workers, so the system task doesn't end/restart between files.
			if self.activeTokens.isEmpty {
				let succeeded = self.batches.values.allSatisfy { $0.failed == 0 && $0.terminal >= $0.total }
				BackgroundTaskManager.shared.release(.importing, success: succeeded)
				self.batches.removeAll()
			}
		}
	}

	private func publish() {
		let total = batches.values.reduce(0) { $0 + $1.total }
		guard total > 0 else { return }

		let completed = batches.values.reduce(0) { $0 + $1.completed }
		let failed = batches.values.reduce(0) { $0 + $1.failed }
		let terminal = completed + failed
		let detail: String
		if terminal >= total {
			detail = failed == 0 ? "Completed" : "Error"
		} else {
			detail = "Importing"
		}

		BackgroundTaskManager.shared.report(
			.importing,
			completed: completed,
			total: total,
			fraction: nil,
			detail: detail
		)
	}
}

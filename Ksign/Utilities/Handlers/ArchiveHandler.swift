//
//  ArchiveHandler.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import Foundation
import UIKit.UIApplication
import ASignArchiveKit
import IDeviceSwift

// Shared with the job owner: invalidation is synchronous, including while a
// native worker cannot cooperatively cancel. Pending progress checks it again
// at delivery time so old attempts cannot update a retry's UI.
final class PackagingAttempt: @unchecked Sendable {
	let id = UUID()
	private let lock = NSLock()
	private var cancelled = false
	var isCurrent: Bool {
		lock.lock()
		defer { lock.unlock() }
		return !cancelled
	}
	func cancel() {
		lock.lock()
		cancelled = true
		lock.unlock()
	}
}

// At most one scheduled delivery and one latest value per producer. This also
// bounds callback/autorelease work for directories with thousands of entries.
private final class PackageProgressDelivery {
	private static let queue = DispatchQueue(label: "nya.asami.ksign.package-progress", qos: .userInitiated)
	private let lock = NSLock()
	private var latest: Double?
	private var scheduled = false
	private let deliver: (Double) -> Void
	init(deliver: @escaping (Double) -> Void) { self.deliver = deliver }
	func submit(_ value: Double) {
		lock.lock()
		latest = value
		let enqueue = !scheduled
		scheduled = true
		lock.unlock()
		if enqueue {
			Self.queue.asyncAfter(deadline: .now() + 0.1) { self.drain() }
		}
	}
	func flush() { Self.queue.sync { drain() } }
	private func drain() {
		lock.lock()
		let value = latest
		latest = nil
		scheduled = false
		lock.unlock()
		if let value { autoreleasepool { deliver(value) } }
	}
}

// Keeps high-frequency package progress from building an unbounded backlog of
// main-queue blocks while Ksign is backgrounded or while the main thread is
// temporarily busy. Packaging itself and all non-UI progress reporting continue
// at full cadence; only the drawer's package-progress delivery hop is coalesced.
//
// While active, a producer that the main queue can keep up with still delivers
// every update. If another value arrives while one delivery is already queued,
// the queued delivery picks up the newest value instead of adding another block.
// While inactive, no package-progress blocks are enqueued at all; only the newest
// value per view model is retained and flushed on didBecomeActive.
final class PackageProgressUIBridge {
	static let shared = PackageProgressUIBridge()

	private struct Pending {
		var latest: (() -> Void)?
		var deliveryQueued = false
	}

	private let _lock = NSLock()
	private var _isAppActive = false
	private var _pending: [ObjectIdentifier: Pending] = [:]
	private var _observers: [NSObjectProtocol] = []

	private init() {
		let center = NotificationCenter.default

		_observers.append(center.addObserver(
			forName: UIApplication.willResignActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			self?._setAppActive(false)
		})

		_observers.append(center.addObserver(
			forName: UIApplication.didEnterBackgroundNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			self?._setAppActive(false)
		})

		_observers.append(center.addObserver(
			forName: UIApplication.didBecomeActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			self?._setAppActive(true)
		})

		// The singleton can first be touched by an archive worker, so take the
		// UIKit state snapshot on main rather than assuming init ran there.
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			self._setAppActive(UIApplication.shared.applicationState == .active)
		}
	}

	deinit {
		for observer in _observers {
			NotificationCenter.default.removeObserver(observer)
		}
	}

	func submit(
		_ value: Double,
		to viewModel: InstallerStatusViewModel,
		isCurrent: @escaping () -> Bool = { true }
	) {
		let key = ObjectIdentifier(viewModel)
		var shouldQueueDelivery = false

		_lock.lock()
		var entry = _pending[key] ?? Pending()
		entry.latest = { [weak viewModel] in
			if isCurrent() { viewModel?.packageProgress = value }
		}

		if _isAppActive && !entry.deliveryQueued {
			entry.deliveryQueued = true
			shouldQueueDelivery = true
		}

		_pending[key] = entry
		_lock.unlock()

		if shouldQueueDelivery {
			_queueDelivery(for: key)
		}
	}

	private func _queueDelivery(for key: ObjectIdentifier) {
		DispatchQueue.main.async { [weak self] in
			self?._deliverLatest(for: key)
		}
	}

	private func _deliverLatest(for key: ObjectIdentifier) {
		var update: (() -> Void)?

		_lock.lock()
		guard _isAppActive, var entry = _pending[key] else {
			if var entry = _pending[key] {
				entry.deliveryQueued = false
				_pending[key] = entry
			}
			_lock.unlock()
			return
		}

		// Consume the newest value available now. A callback arriving while this
		// assignment runs simply becomes the next latest value for this job.
		update = entry.latest
		entry.latest = nil
		_pending[key] = entry
		_lock.unlock()

		update?()

		var shouldQueueAgain = false
		_lock.lock()
		if var entry = _pending[key] {
			if _isAppActive, entry.latest != nil {
				// Keep deliveryQueued true: this key still has exactly one drawer
				// update outstanding, never an unbounded list of stale updates.
				shouldQueueAgain = true
				_pending[key] = entry
			} else if entry.latest == nil {
				// No pending value remains, so don't retain idle job identifiers.
				_pending.removeValue(forKey: key)
			} else {
				// The app became inactive while the delivery was running. Keep
				// only the newest value and let didBecomeActive flush it later.
				entry.deliveryQueued = false
				_pending[key] = entry
			}
		}
		_lock.unlock()

		if shouldQueueAgain {
			_queueDelivery(for: key)
		}
	}

	private func _setAppActive(_ active: Bool) {
		var keysToFlush: [ObjectIdentifier] = []

		_lock.lock()
		_isAppActive = active

		if active {
			for key in Array(_pending.keys) {
				guard var entry = _pending[key],
					entry.latest != nil,
					!entry.deliveryQueued
				else { continue }

				entry.deliveryQueued = true
				_pending[key] = entry
				keysToFlush.append(key)
			}
		}
		_lock.unlock()

		for key in keysToFlush {
			_queueDelivery(for: key)
		}
	}
}

final class ArchiveHandler: NSObject, FileManagerDelegate {
	// This is a worker-owned helper, not a SwiftUI view. Avoid property-wrapper
	// actor inference here; PackageProgressUIBridge owns all UI assignments.
	let viewModel: InstallerStatusViewModel
	
	private let _fileManager = FileManager()
	private let _uuid = UUID().uuidString
	private var _payloadUrl: URL?
	
	private var _app: AppInfoPresentable
	private let _uniqueWorkDir: URL
	private let _progressReporter: ((Double) -> Void)?
	private let _uiProgressReporter: ((Double) -> Void)?
	private let _attempt: PackagingAttempt
	private let _jobID: UUID
	private var _workload = ArchiveWorkload()
	private lazy var _progressDelivery = PackageProgressDelivery { [weak self] value in
		self?._deliverPackagingProgress(value)
	}

	// Packaging has two real pieces of work before the install prompt can fire:
	// preparing Payload (recursive hard-link/copy) and creating the IPA. The
	// archive library already reports byte progress for the second half; FileManager
	// exposes per-item delegate callbacks for the first. Keep them on one monotonic
	// 0...1 scale so BGContinuedProcessingTask never sees the packaging phase sit
	// motionless while Payload is being assembled.
	private static let _preparationWeight = 0.10
	private var _preparationTotalItems = 1
	private var _preparationVisitedItems = 0
	private var _preparationReporting = false
	
	// Exposed so whoever owns the install can delete this once the archive has
	// actually been consumed. Nothing used to: every install left a full-size
	// Archive.ipa in tmp, and `FeatherApp._clean()` only runs at launch — so a
	// sixteen-app batch stacked up sixteen of them and held that space until
	// the next cold start.
	var workDir: URL { _uniqueWorkDir }
	
	init(
		app: AppInfoPresentable,
		viewModel: InstallerStatusViewModel,
		progressReporter: ((Double) -> Void)? = nil,
		uiProgressReporter: ((Double) -> Void)? = nil,
		attempt: PackagingAttempt = PackagingAttempt(),
		jobID: UUID = UUID()
	) {
		self.viewModel = viewModel
		self._app = app
		self._progressReporter = progressReporter
		self._uiProgressReporter = uiProgressReporter
		self._attempt = attempt
		self._jobID = jobID
		self._uniqueWorkDir = _fileManager.temporaryDirectory
			.appendingPathComponent("FeatherInstall_\(_uuid)", isDirectory: true)
		
		super.init()
		_fileManager.delegate = self
	}
	
	// Safe at any point, and safe to call twice. The share flow moves the .ipa
	// out to Documents/App/Archives first, so this only removes what's left.
	//
	// Deliberately not called straight after `archive()`: the server streams
	// the payload from this directory, so it has to survive until the install
	// reaches a terminal state.
	static func cleanup(workDir: URL) {
		autoreleasepool { try? FileManager.default.removeItem(at: workDir) }
	}
	
	func cleanup() {
		Self.cleanup(workDir: _uniqueWorkDir)
	}
	
	func move() async throws {
		try Task.checkCancellation()
		guard let appUrl = Storage.shared.getAppDirectory(for: _app) else {
			throw SigningFileHandlerError.appNotFound
		}
		
		let payloadUrl = _uniqueWorkDir.appendingPathComponent("Payload")
		let movedAppURL = payloadUrl.appendingPathComponent(appUrl.lastPathComponent)

		try _fileManager.createDirectoryIfNeeded(at: payloadUrl)
		try _beginPreparationProgress(for: appUrl)
		defer { _preparationReporting = false }
		
		// Hard links rather than a copy. FileManager recursively links directory
		// contents and invokes our delegate for each item, so this formerly silent
		// setup phase now contributes real package/BGTask progress too.
		try autoreleasepool {
			do {
				try _fileManager.linkItem(at: appUrl, to: movedAppURL)
			} catch {
				try Task.checkCancellation()
				// Recursive copy uses the same delegate progress path.
				try _fileManager.copyItem(at: appUrl, to: movedAppURL)
			}
		}
		try Task.checkCancellation()

		_reportPackagingProgress(Self._preparationWeight)
		_payloadUrl = payloadUrl
	}
	
	func archive() async throws -> URL {
		let attempt = _attempt
		let worker = Task.detached(priority: .userInitiated) { [self] in
			let gate = ArchiveMemoryCoordinator.shared
			let compression = ASignArchiveCompression(rawValue: Self.getCompressionLevel()) ?? .none
			var workload = self._workload
			workload.compression = compression.rawValue
			let lease: ArchiveMemoryCoordinator.Lease
			do {
				try Task.checkCancellation()
				guard attempt.isCurrent else { throw CancellationError() }
				lease = try await gate.acquire(job: self._jobID, attempt: attempt.id, workload: workload)
			} catch {
				self.cleanup()
				throw error
			}

			var result: Result<URL, Error>
			do {
				let package = try autoreleasepool {
					// Cancellation after grant still owns a lease, even if no native
					// work has begun. The common exit below always releases it.
					try Task.checkCancellation()
					guard attempt.isCurrent else { throw CancellationError() }
					guard let payloadUrl = self._payloadUrl else {
						throw SigningFileHandlerError.appNotFound
					}
					let zipUrl = self._uniqueWorkDir.appendingPathComponent("Archive.zip")
					let ipaUrl = self._uniqueWorkDir.appendingPathComponent("Archive.ipa")
					gate.checkpoint(lease, "before archive lifecycle")
					try ASignArchive.create(
						from: payloadUrl, at: zipUrl, compression: compression,
						beforeNative: {
							try Task.checkCancellation()
							guard attempt.isCurrent else { throw CancellationError() }
							gate.checkpoint(lease, "before native")
						},
						afterNative: { gate.checkpoint(lease, "native returned") },
						progress: { progress in
							self._reportPackagingProgress(Self._preparationWeight + progress * (1 - Self._preparationWeight))
						}
					)
					// Never interrupt synchronous minizip. A cancelled writer gets
					// here normally and its closed output is discarded below.
					try Task.checkCancellation()
					guard attempt.isCurrent else { throw CancellationError() }
					try FileManager.default.moveItem(at: zipUrl, to: ipaUrl)
					return ipaUrl
				}
				result = .success(package)
			} catch {
				result = .failure(error)
			}
			if case .success = result { self._reportPackagingProgress(1) }
			self._progressDelivery.flush()
			gate.checkpoint(lease, "temporary objects released")
			await gate.settle()
			if Task.isCancelled || !attempt.isCurrent { result = .failure(CancellationError()) }
			let succeeded: Bool
			switch result {
			case .success:
				succeeded = true
			case .failure:
				succeeded = false
				// No writer is alive now. Keep the lease until file cleanup ends.
				self.cleanup()
			}
			gate.checkpoint(lease, "settled and cleanup complete")
			gate.finish(lease, succeeded: succeeded)
			return try result.get()
		}
		return try await withTaskCancellationHandler {
			try await worker.value
		} onCancel: {
			attempt.cancel()
			worker.cancel()
		}
	}

	func moveToArchive(_ package: URL, shouldOpen: Bool = false) async throws -> URL? {
		let appendingString = "\(_app.name!)_\(_app.version!)_\(Int(Date().timeIntervalSince1970)).ipa"
		let dest = _fileManager.archives.appendingPathComponent(appendingString)
		
		try? _fileManager.moveItem(
			at: package,
			to: dest
		)
		
		if shouldOpen {
			await MainActor.run {
				UIApplication.open(FileManager.default.archives.toSharedDocumentsURL()!)
			}
		}
		
		return dest
	}
	

	// MARK: - Packaging progress

	private func _beginPreparationProgress(for appURL: URL) throws {
		_workload = ArchiveWorkload(entries: 1, pathBytes: Double(appURL.path.utf8.count))
		let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
		if let enumerator = _fileManager.enumerator(
			at: appURL,
			includingPropertiesForKeys: Array(keys),
			options: [],
			errorHandler: { [self] _, _ in self._workload.complete = false; return true }
		) {
			// nextObject belongs inside the pool too: enumerated NSURLs and
			// prefetched resource values must not accumulate across the scan.
			while try autoreleasepool(invoking: {
				try Task.checkCancellation()
				guard let url = enumerator.nextObject() as? URL else { return false }
				_workload.entries += 1
				_workload.pathBytes += Double(url.path.utf8.count)
				do {
					let values = try url.resourceValues(forKeys: keys)
					if values.isRegularFile == true && values.isSymbolicLink != true {
						_workload.uncompressedBytes += Double(values.fileSize ?? 0)
					}
				} catch { _workload.complete = false }
				return true
			}) { }
		} else { _workload.complete = false }

		_preparationTotalItems = max(1, Int(_workload.entries))
		_preparationVisitedItems = 0
		_preparationReporting = true
		_reportPackagingProgress(0)
	}

	private func _advancePreparationProgress() {
		guard _preparationReporting else { return }
		_preparationVisitedItems = min(
			_preparationTotalItems,
			_preparationVisitedItems + 1
		)
		let fraction = Double(_preparationVisitedItems) / Double(_preparationTotalItems)
		_reportPackagingProgress(fraction * Self._preparationWeight)
	}

	private func _reportPackagingProgress(_ progress: Double) {
		guard _attempt.isCurrent else { return }
		_progressDelivery.submit(min(1, max(0, progress)))
	}

	private func _deliverPackagingProgress(_ value: Double) {
		guard _attempt.isCurrent else { return }
		_progressReporter?(value)
		if let uiProgressReporter = _uiProgressReporter {
			uiProgressReporter(value)
		} else {
			let attempt = _attempt
			PackageProgressUIBridge.shared.submit(value, to: viewModel, isCurrent: { attempt.isCurrent })
		}
	}

	func fileManager(
		_ fileManager: FileManager,
		shouldLinkItemAt srcURL: URL,
		to dstURL: URL
	) -> Bool {
		_advancePreparationProgress()
		return true
	}

	func fileManager(
		_ fileManager: FileManager,
		shouldCopyItemAt srcURL: URL,
		to dstURL: URL
	) -> Bool {
		_advancePreparationProgress()
		return true
	}

	static func getCompressionLevel() -> Int {
		UserDefaults.standard.integer(forKey: "Feather.compressionLevel")
	}
}

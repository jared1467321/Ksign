//
//  ArchiveHandler.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import Foundation
import UIKit.UIApplication
import ASignArchiveKit
import SwiftUI
import IDeviceSwift

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
		to viewModel: InstallerStatusViewModel
	) {
		let key = ObjectIdentifier(viewModel)
		var shouldQueueDelivery = false

		_lock.lock()
		var entry = _pending[key] ?? Pending()
		entry.latest = { [weak viewModel] in
			viewModel?.packageProgress = value
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
	@ObservedObject var viewModel: InstallerStatusViewModel
	
	private let _fileManager = FileManager()
	private let _uuid = UUID().uuidString
	private var _payloadUrl: URL?
	
	private var _app: AppInfoPresentable
	private let _uniqueWorkDir: URL
	private let _progressReporter: ((Double) -> Void)?
	private let _uiProgressReporter: ((Double) -> Void)?

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
		uiProgressReporter: ((Double) -> Void)? = nil
	) {
		self.viewModel = viewModel
		self._app = app
		self._progressReporter = progressReporter
		self._uiProgressReporter = uiProgressReporter
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
		try? FileManager.default.removeItem(at: workDir)
	}
	
	func cleanup() {
		Self.cleanup(workDir: _uniqueWorkDir)
	}
	
	func move() async throws {
		guard let appUrl = Storage.shared.getAppDirectory(for: _app) else {
			throw SigningFileHandlerError.appNotFound
		}
		
		let payloadUrl = _uniqueWorkDir.appendingPathComponent("Payload")
		let movedAppURL = payloadUrl.appendingPathComponent(appUrl.lastPathComponent)

		try _fileManager.createDirectoryIfNeeded(at: payloadUrl)
		_beginPreparationProgress(for: appUrl)
		defer { _preparationReporting = false }
		
		// Hard links rather than a copy. FileManager recursively links directory
		// contents and invokes our delegate for each item, so this formerly silent
		// setup phase now contributes real package/BGTask progress too.
		do {
			try _fileManager.linkItem(at: appUrl, to: movedAppURL)
		} catch {
			// Falls back to the old behaviour if linking isn't possible. Recursive
			// copy uses the same delegate progress path, so BGTaskManager continues
			// seeing forward movement here as well.
			try _fileManager.copyItem(at: appUrl, to: movedAppURL)
		}

		_reportPackagingProgress(Self._preparationWeight)
		_payloadUrl = payloadUrl
	}
	
	func archive() async throws -> URL {
		// `.userInitiated`, not `.background`.
		//
		// Zipping the payload is the most CPU-heavy step in the install
		// pipeline, and it was running at the lowest quality of service iOS
		// offers. `.background` isn't just "a bit lower" — it's the tier the
		// system throttles on purpose: reduced scheduling priority, throttled
		// disk I/O, and deferral outright when the device is under thermal or
		// CPU pressure. That's the correct tier for work nobody is waiting on,
		// and precisely the wrong one for work with a progress bar attached to
		// it that the user is staring at.
		//
		// `.userInitiated` is the right level — the user asked for this and is
		// blocked until it finishes. Not `.userInteractive`, which is reserved
		// for keeping the UI itself responsive.
		return try await Task.detached(priority: .userInitiated) { [self] in
			guard let payloadUrl = await self._payloadUrl else {
				throw SigningFileHandlerError.appNotFound
			}
			
			let zipUrl = self._uniqueWorkDir.appendingPathComponent("Archive.zip")
			let ipaUrl = self._uniqueWorkDir.appendingPathComponent("Archive.ipa")
			
			let compression = ASignArchiveCompression(
				rawValue: ArchiveHandler.getCompressionLevel()
			) ?? .none

			try ASignArchive.create(
				from: payloadUrl,
				at: zipUrl,
				compression: compression,
				progress: { progress in
					// Payload preparation owns the first slice of package progress. Map
					// minizip's real byte progress across the remainder so the combined
					// value never resets when archiving begins.
					let mapped = Self._preparationWeight
						+ (progress * (1 - Self._preparationWeight))
					self._reportPackagingProgress(mapped)
				}
			)
			
			try FileManager.default.moveItem(at: zipUrl, to: ipaUrl)
			self._reportPackagingProgress(1)
			return ipaUrl
		}.value
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

	private func _beginPreparationProgress(for appURL: URL) {
		var count = 1 // The .app directory itself.
		if let enumerator = _fileManager.enumerator(
			at: appURL,
			includingPropertiesForKeys: nil,
			options: [],
			errorHandler: { _, _ in true }
		) {
			while enumerator.nextObject() != nil { count += 1 }
		}

		_preparationTotalItems = max(1, count)
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
		let value = min(1, max(0, progress))
		_progressReporter?(value)

		if let uiProgressReporter = _uiProgressReporter {
			uiProgressReporter(value)
		} else {
			// Preserve the existing behavior for single-install/export callers.
			Task { @MainActor in
				self.viewModel.packageProgress = value
			}
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

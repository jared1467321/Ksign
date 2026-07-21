//
//  ArchiveHandler.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import Foundation
import UIKit.UIApplication
import Zip
import SwiftUI
import IDeviceSwift

final class ArchiveHandler: NSObject {
	@ObservedObject var viewModel: InstallerStatusViewModel
	
	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
	private var _payloadUrl: URL?
	
	private var _app: AppInfoPresentable
	private let _uniqueWorkDir: URL
	
	// Exposed so whoever owns the install can delete this once the archive has
	// actually been consumed. Nothing used to: every install left a full-size
	// Archive.ipa in tmp, and `FeatherApp._clean()` only runs at launch — so a
	// sixteen-app batch stacked up sixteen of them and held that space until
	// the next cold start.
	var workDir: URL { _uniqueWorkDir }
	
	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) {
		self.viewModel = viewModel
		self._app = app
		self._uniqueWorkDir = _fileManager.temporaryDirectory
			.appendingPathComponent("FeatherInstall_\(_uuid)", isDirectory: true)
		
		super.init()
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
		
		// Hard links rather than a copy. Zipping only ever reads these files,
		// and both paths live in the app's own container, so linking gives the
		// archiver the layout it needs without moving a single byte. On a
		// 400MB app this turns the slowest step in the pipeline into a no-op.
		do {
			try _fileManager.linkItem(at: appUrl, to: movedAppURL)
		} catch {
			// Falls back to the old behaviour if linking isn't possible.
			try _fileManager.copyItem(at: appUrl, to: movedAppURL)
		}

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
			
			try await Zip.zipFiles(
				paths: [payloadUrl],
				zipFilePath: zipUrl,
				password: nil,
				compression: ZipCompression.allCases[ArchiveHandler.getCompressionLevel()],
				progress: { progress in
					
					Task { @MainActor in
						self.viewModel.packageProgress = progress
					}
				})
			
			try FileManager.default.moveItem(at: zipUrl, to: ipaUrl)
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
	
	static func getCompressionLevel() -> Int {
		UserDefaults.standard.integer(forKey: "Feather.compressionLevel")
	}
}

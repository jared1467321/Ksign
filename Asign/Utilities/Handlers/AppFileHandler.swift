//
//  IPAHandler.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//

import Foundation

final class AppFileHandler: NSObject, @unchecked Sendable {
	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
	private let _uniqueWorkDir: URL

	private let _ipa: URL
	private let _install: Bool
	private let _download: Download?
	private var _metadata: ArchiveBackedAppMetadata?
	private var _cachedIconURL: URL?
	private var _canonicalArchiveURL: URL?
	private var _usedMove = false
	private var _committed = false

	init(
		file ipa: URL,
		install: Bool = false,
		download: Download? = nil
	) {
		self._ipa = ipa
		self._install = install
		self._download = download
		self._uniqueWorkDir = _fileManager.temporaryDirectory
			.appendingPathComponent("FeatherImport_\(_uuid)", isDirectory: true)
		
		super.init()
		print("Import initiated for: \(_ipa.lastPathComponent) with ID: \(_uuid)")
	}

	/// Archive-backed imports deliberately keep the IPA compressed. This stage
	/// validates the archive and reads only the root Info.plist plus (when one can
	/// be resolved) the primary icon used by the library UI.
	func extract() async throws {
		try Task.checkCancellation()

		let archive = try ArchiveBackedApp(archiveURL: _ipa)
		let metadata = try archive.metadata()
		_metadata = metadata

		// The library can use its placeholder icon. A damaged icon or a cache
		// write failure must not prevent importing an otherwise readable IPA.
		do {
			_cachedIconURL = try archive.cachePrimaryIcon(in: _uniqueWorkDir, metadata: metadata)
				.map { _uniqueWorkDir.appendingPathComponent($0) }
		} catch is CancellationError {
			throw CancellationError()
		} catch {
			_cachedIconURL = nil
			print("[\(_uuid)] Import continuing without an icon: \(error.localizedDescription)")
		}
		// Optional artwork failures may be ignored; a replaced or changing IPA
		// must still fail rather than be saved with metadata from an older file.
		try archive.archiveIndex.validate()
		try Task.checkCancellation()
		_reportProgress(1)
		print("[\(_uuid)] Archive-backed import prepared; no Payload extraction performed")
	}

	/// Move the canonical IPA into Unsigned/<UUID>/Archive.ipa. Files/provider
	/// URLs and cross-volume sources can reject a move; copying is the fallback.
	func move() async throws {
		try Task.checkCancellation()
		guard _metadata != nil else { throw ImportedFileHandlerError.extractionFailed }

		let destinationDirectory = try await _directory()
		try _fileManager.createDirectoryIfNeeded(at: destinationDirectory)
		let destinationArchive = destinationDirectory.appendingPathComponent("Archive.ipa")
		try _fileManager.removeFileIfNeeded(at: destinationArchive)

		// The explicit "save App Store downloads" preference means the user
		// asked to retain that downloaded IPA in Documents/Downloads. Preserve it
		// and copy into the library; every other import still prefers a true move.
		let preserveDownloadedSource = _download != nil && OptionsManager.shared.options.saveAppStoreDownloadsToDownloadsFolder
		if preserveDownloadedSource {
			try _fileManager.copyItem(at: _ipa, to: destinationArchive)
			_usedMove = false
			print("[\(_uuid)] Preserved saved download; copied IPA to: \(destinationArchive.path)")
		} else {
			do {
				try _fileManager.moveItem(at: _ipa, to: destinationArchive)
				_usedMove = true
				print("[\(_uuid)] Moved IPA directly to: \(destinationArchive.path)")
			} catch {
				try Task.checkCancellation()
				try _fileManager.removeFileIfNeeded(at: destinationArchive)
				try _fileManager.copyItem(at: _ipa, to: destinationArchive)
				_usedMove = false
				print("[\(_uuid)] Source could not be moved; copied IPA to: \(destinationArchive.path)")
			}
		}

		_canonicalArchiveURL = destinationArchive

		if let cachedIconURL = _cachedIconURL,
			_fileManager.fileExists(atPath: cachedIconURL.path) {
			let iconDestination = destinationDirectory.appendingPathComponent(cachedIconURL.lastPathComponent)
			do {
				try _fileManager.moveItem(at: cachedIconURL, to: iconDestination)
				_cachedIconURL = iconDestination
			} catch {
				_cachedIconURL = nil
				try? _fileManager.removeFileIfNeeded(at: iconDestination)
				print("[\(_uuid)] Import continuing without an icon: \(error.localizedDescription)")
			}
		} else {
			_cachedIconURL = nil
		}

		try? _fileManager.removeItem(at: _uniqueWorkDir)
	}

	func addToDatabase() async throws {
		guard let metadata = _metadata else {
			throw ImportedFileHandlerError.extractionFailed
		}

		let iconName = _cachedIconURL?.lastPathComponent
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			Storage.shared.addImported(
				uuid: _uuid,
				source: _canonicalArchiveURL ?? _ipa,
				appName: metadata.name,
				appIdentifier: metadata.identifier,
				appVersion: metadata.version,
				appIcon: iconName
			) { error in
				if let error {
					continuation.resume(throwing: error)
					return
				}
				print("[\(self._uuid)] Added archive-backed app to database (\(self._usedMove ? "move" : "copy"))")
				continuation.resume()
			}
		}
		_committed = true
	}

	private func _directory() async throws -> URL {
		_fileManager.unsigned(_uuid)
	}

	var retainedArchiveURL: URL? {
		guard let url = _canonicalArchiveURL,
			_fileManager.fileExists(atPath: url.path) else { return nil }
		return url
	}

	func clean() async throws {
		if !_committed {
			if _usedMove, let archiveURL = _canonicalArchiveURL {
				// Restore the moved source before removing an uncommitted import.
				// If restoration fails, retain the IPA and report its recovery path.
				do {
					try _fileManager.moveItem(at: archiveURL, to: _ipa)
				} catch {
					print("[\(_uuid)] Could not restore source; IPA retained at \(archiveURL.path): \(error.localizedDescription)")
					throw error
				}
			}
			try _fileManager.removeFileIfNeeded(at: _fileManager.unsigned(_uuid))
		}
		try _fileManager.removeFileIfNeeded(at: _uniqueWorkDir)
	}

	private func _reportProgress(_ progress: Double) {
		guard let download = _download else { return }
		DispatchQueue.main.async {
			download.unpackageProgress = progress
			BackgroundTaskManager.shared.updateProgress(for: download.id, progress: download.overallProgress)
		}
	}
}

struct AppImportError: LocalizedError {
	enum Stage: String {
		case reading = "reading the IPA metadata"
		case storing = "saving the IPA to the library"
		case registering = "saving the library record"
	}

	let fileName: String
	let stage: Stage
	let underlyingError: Error
	var recoveryURL: URL? = nil

	var errorDescription: String? {
		var message = "Could not import \"\(fileName)\" while \(stage.rawValue).\n\n\(underlyingError.localizedDescription)"
		if let recoveryURL {
			message += "\n\nThe IPA has been kept at: \(recoveryURL.path)"
		}
		return message
	}
}

enum ImportedFileHandlerError: LocalizedError, CustomStringConvertible {
	case payloadNotFound
	case notEnoughDiskSpace(needed: Int64, available: Int64)
	case extractionFailed
	case zipLibraryNotAvailable

	var errorDescription: String? { description }
	
	var description: String {
		switch self {
		case .payloadNotFound:
			return "No Payload folder was found in the archive. The file may be corrupted."
		case .notEnoughDiskSpace(let needed, let available):
			let neededStr = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
			let availableStr = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
			return "Not enough disk space. Needed: \(neededStr), Available: \(availableStr)"
		case .extractionFailed:
			return "Failed to read the archive. The file may be corrupted."
		case .zipLibraryNotAvailable:
			return "The archive library is not available on this platform."
		}
	}
}

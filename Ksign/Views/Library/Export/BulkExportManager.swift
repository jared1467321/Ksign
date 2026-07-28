//
//  BulkExportManager.swift
//  Ksign
//
//  Archives a batch of selected apps into .ipa files, one at a time, then
//  hands the finished files to a document picker so they can be saved wherever
//  the user wants. Kept intentionally simple and self-contained — it does not
//  touch the install queue.
//

import SwiftUI
import UIKit
import NimbleExtensions
import IDeviceSwift

@MainActor
final class BulkExportManager: ObservableObject {
	// Whether archiving is currently running (drives the progress overlay).
	@Published private(set) var isExporting = false
	// Flips true once archiving finishes and there are files to save. The view
	// watches this to present the document picker.
	@Published var readyToPick = false

	@Published private(set) var total = 0
	@Published private(set) var completed = 0
	@Published private(set) var currentName = ""

	// Finished .ipa files, awaiting the picker. Their parent work dirs are held
	// in `_workDirs` and removed once the picker is done.
	@Published private(set) var exportURLs: [URL] = []

	private var _workDirs: [URL] = []
	private var _failures: [String] = []
	private var _cancelled = false

	// Progress across the batch, counted per app. The zip step for one app has
	// no sub-progress here on purpose — the current-app spinner in the overlay
	// is what shows it's still working, so this stays dependency-free.
	var overallProgress: Double {
		guard total > 0 else { return 0 }
		return min(1.0, Double(completed) / Double(total))
	}

	// Mirrors the batch position into the keep-alive's Dynamic Island bar.
	// Counted per app, same as the on-screen overlay — the zip step for a
	// single app has no sub-progress to offer.
	private func _reportProgress() {
		guard #available(iOS 16.2, *) else { return }
		KeepAliveActivityController.shared.report(
			.bulkExport,
			completed: completed,
			total: isExporting ? total : nil
		)

		// The app being zipped right now — the same string the on-screen
		// overlay shows.
		KeepAliveActivityController.shared.report(
			.bulkExport,
			detail: isExporting && !currentName.isEmpty ? currentName : nil
		)
	}

	// MARK: - Lifecycle

	func start(apps: [AppInfoPresentable]) {
		guard !apps.isEmpty, !isExporting else { return }

		_reset()
		total = apps.count
		isExporting = true
		BackgroundAudioManager.shared.claim(.bulkExport)
		_reportProgress()

		Task { await _run(apps) }
	}

	func cancel() {
		_cancelled = true
	}

	// Called by the view once the document picker finishes (saved or cancelled).
	// Idempotent — safe to call from both the picker's completion and the
	// sheet's onDisappear.
	func finishPicking() {
		readyToPick = false
		_cleanupWorkDirs()
		_reset()
		_reportProgress()
		BackgroundAudioManager.shared.release(.bulkExport)
	}

	// MARK: - Work

	private func _run(_ apps: [AppInfoPresentable]) async {
		var usedNames = Set<String>()

		for app in apps {
			if _cancelled { break }

			currentName = app.name ?? .localized("Unknown")

			let viewModel = InstallerStatusViewModel(isIdevice: false)

			do {
				let handler = ArchiveHandler(app: app, viewModel: viewModel)
				try await handler.move()
				let packageUrl = try await handler.archive()

				// Rename Archive.ipa to something recognisable, keeping names
				// unique within this batch so the picker doesn't collide.
				let fileName = _uniqueFileName(for: app, used: &usedNames)
				let dest = handler.workDir.appendingPathComponent(fileName)
				try? FileManager.default.removeItem(at: dest)
				try FileManager.default.moveItem(at: packageUrl, to: dest)

				exportURLs.append(dest)
				_workDirs.append(handler.workDir)
			} catch {
				_failures.append(app.name ?? .localized("Unknown"))
			}

			completed += 1
			_reportProgress()
		}

		isExporting = false

		if !exportURLs.isEmpty {
			readyToPick = true
		} else {
			_cleanupWorkDirs()
			BackgroundAudioManager.shared.release(.bulkExport)
			_reportFailuresIfNeeded()
			_reset()
		}
	}

	// MARK: - Helpers

	private func _uniqueFileName(for app: AppInfoPresentable, used: inout Set<String>) -> String {
		let rawName = app.name ?? .localized("Unknown")
		let name = rawName.replacingOccurrences(of: "/", with: "-")
		let version = app.version ?? "0"

		var candidate = "\(name)_\(version).ipa"
		var counter = 2
		while used.contains(candidate) {
			candidate = "\(name)_\(version)_\(counter).ipa"
			counter += 1
		}
		used.insert(candidate)
		return candidate
	}

	private func _cleanupWorkDirs() {
		for dir in _workDirs {
			ArchiveHandler.cleanup(workDir: dir)
		}
		_workDirs.removeAll()
	}

	private func _reportFailuresIfNeeded() {
		guard !_failures.isEmpty else { return }
		let message = _failures.joined(separator: "\n")
		UIAlertController.showAlertWithOk(
			title: .localized("Export"),
			message: .localized("Couldn't export:\n%@", arguments: message)
		)
	}

	private func _reset() {
		total = 0
		completed = 0
		currentName = ""
		exportURLs = []
		_failures = []
		_cancelled = false
	}
}

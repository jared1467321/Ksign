//
//  ResetView.swift
//  Feather
//
//  Created by samara on 19.06.2025.
//

import CoreData
import NimbleExtensions
import NimbleViews
import Nuke
import SwiftUI

// MARK: - View
struct ResetView: View {
	@State private var isResetting = false
	// MARK: Body
	var body: some View {
		NBList(("Reset")) {
			_cache()
			_coredata()
			_all()
		}
		.disabled(isResetting)
		.overlay { if isResetting { ProgressView("Working…") } }
	}

	private func _cacheSize() async -> String {
		(try? await BackgroundFileWork.perform { Self.cacheSizeOnWorker() }) ?? ""
	}

	nonisolated private static func cacheSizeOnWorker() -> String {
		var totalCacheSize = URLCache.shared.currentDiskUsage
		if let nukeCache = ImagePipeline.shared.configuration.dataCache as? DataCache {
			totalCacheSize += nukeCache.totalSize
		}
		return
			"\(ByteCountFormatter.string(fromByteCount: Int64(totalCacheSize), countStyle: .file))"
	}

	private func resetAlert(
		title: String,
		message: String = "",
		action: @escaping @MainActor () async -> Void
	) {
		let action = UIAlertAction(
			title: ("Proceed"),
			style: .destructive
		) { _ in
			Task { @MainActor in
				guard !isResetting else { return }
				isResetting = true
				await action()
				isResetting = false
				UIApplication.shared.suspendAndReopen()
			}
		}

		let style: UIAlertController.Style =
			UIDevice.current.userInterfaceIdiom == .pad
			? .alert
			: .actionSheet

		var msg = ""
		if !message.isEmpty { msg = message + "\n" }
		msg.append(("This action cannot be undone. Would you like to proceed?"))

		UIAlertController.showAlertWithCancel(
			title: title,
			message: msg,
			style: style,
			actions: [action]
		)
	}
}

// MARK: - View extension
extension ResetView {
	@ViewBuilder
	private func _cache() -> some View {
		Section {
			Button(
				"Reset Network And Work Cache",
				systemImage: "xmark.rectangle.portrait"
			) {
				Task { @MainActor in
					resetAlert(
						title: "Reset Network And Work Cache",
						message: await _cacheSize()
					) {
						await Self.clearWorkCache()
						await Self.clearNetworkCache()
					}
				}
			}
		}
	}

	@ViewBuilder
	private func _coredata() -> some View {
		Section {
			Button("Reset Sources", systemImage: "xmark.circle") {
				Task { @MainActor in
					resetAlert(
						title: "Reset Sources",
						message: await Storage.shared.countContent(
							for: AltSource.self)
					) {
						await Self.resetSources()
					}
				}
			}

			Button("Reset Signed Apps", systemImage: "xmark.circle") {
				Task { @MainActor in
					resetAlert(
						title: "Reset Signed Apps",
						message: await Storage.shared.countContent(
							for: Signed.self)
					) {
						await Self.deleteSignedApps()
					}
				}
			}

			Button("Reset Imported Apps", systemImage: "xmark.circle") {
				Task { @MainActor in
					resetAlert(
						title: "Reset Imported Apps",
						message: await Storage.shared.countContent(
							for: Imported.self)
					) {
						await Self.deleteImportedApps()
					}
				}
			}

			Button("Reset Certificates", systemImage: "xmark.circle") {
				Task { @MainActor in
					resetAlert(
						title: "Reset Certificates",
						message: await Storage.shared.countContent(
							for: CertificatePair.self)
					) {
						await Self.resetCertificates()
					}
				}
			}
		}
	}

	@ViewBuilder
	private func _all() -> some View {
		Section {
			Button("Reset Settings", systemImage: "xmark.octagon") {
				Task { @MainActor in
					resetAlert(title: "Reset Settings") {
						Self.resetUserDefaults()
					}
				}
			}

			Button("Reset All", systemImage: "xmark.octagon") {
				Task { @MainActor in
					resetAlert(title: "Reset All") {
						await Self.resetAll()
					}
				}
			}
		}
		.nbThemeForeground(.danger)
	}
}

// MARK: - View extension: reset
extension ResetView {
	static func clearWorkCache() async {
		let removed =
			(try? await BackgroundFileWork.perform { TempMaintenance.clearWorkCache() })
			?? 0
		print("[TempMaintenance] Manual work-cache sweep removed \(removed) item(s)")
	}

	static func clearNetworkCache() async {
		try? await BackgroundFileWork.perform {
			URLCache.shared.removeAllCachedResponses()
			HTTPCookieStorage.shared.removeCookies(since: Date.distantPast)

			if let dataCache = ImagePipeline.shared.configuration.dataCache
				as? DataCache
			{
				dataCache.removeAll()
			}

			if let imageCache = ImagePipeline.shared.configuration.imageCache
				as? Nuke.ImageCache
			{
				imageCache.removeAll()
			}
		}
	}

	static func resetSources() async {
		await Storage.shared.clearContext(request: AltSource.fetchRequest())
	}

	static func deleteSignedApps() async {
		await Storage.shared.clearContext(request: Signed.fetchRequest())
		try? await BackgroundFileWork.perform {
			try FileManager.default.removeFileIfNeeded(at: FileManager.default.signed)
		}
	}

	static func deleteImportedApps() async {
		await Storage.shared.clearContext(request: Imported.fetchRequest())
		try? await BackgroundFileWork.perform {
			try FileManager.default.removeFileIfNeeded(at: FileManager.default.unsigned)
		}
	}

	static func resetCertificates(resetAll: Bool = false) async {
		if !resetAll { UserDefaults.standard.set(0, forKey: "feather.selectedCert") }
		await Storage.shared.clearContext(request: CertificatePair.fetchRequest())
		try? await BackgroundFileWork.perform {
			try FileManager.default.removeFileIfNeeded(
				at: FileManager.default.certificates)
		}
	}

	static func resetUserDefaults() {
		UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
	}

	static func resetAll() async {
		await clearWorkCache()
		await clearNetworkCache()
		await resetSources()
		await deleteSignedApps()
		await deleteImportedApps()
		await resetCertificates(resetAll: true)
		resetUserDefaults()
	}
}

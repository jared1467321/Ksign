//
//  SigningOptionsDylibSharedView.swift
//  Feather
//
//  Created by samara on 19.04.2025.
//

import SwiftUI
import NimbleExtensions
import NimbleViews
import Zsign

// MARK: - View
struct SigningDylibView: View {
	@State private var _dylibs: [String] = []
	@State private var _hiddenDylibCount: Int = 0
	
	var app: AppInfoPresentable
	@Binding var options: Options?
	
	var body: some View {
		NBList(.localized("Dylibs"), type: .list) {
			Section {
				ForEach(_dylibs, id: \.self) { dylib in
					SigningToggleCellView(
						title: dylib,
						options: $options,
						arrayKeyPath: \.disInjectionFiles
					)
				}
			}
			.disabled(options == nil)
			
			NBSection(.localized("Hidden")) {
				Text(verbatim: .localized("%lld required system dylibs not shown", arguments: _hiddenDylibCount))
					.font(.footnote)
					.nbThemeForeground(.disabledText)
			}
		}
		.onAppear(perform: _loadDylibs)
	}
}

// MARK: - Extension: View
extension SigningDylibView {
	private func _loadDylibs() {
		if let archiveURL = Storage.shared.getArchiveURL(for: app) {
			DispatchQueue.global(qos: .userInitiated).async {
				let tempRoot = FileManager.default.temporaryDirectory
					.appendingPathComponent("FeatherArchiveDylibInspect_\(UUID().uuidString)", isDirectory: true)
				defer { try? FileManager.default.removeItem(at: tempRoot) }

				do {
					let archivedApp = try ArchiveBackedApp(archiveURL: archiveURL)
					guard let executable = try archivedApp.metadata().executable, !executable.isEmpty else { return }
					let executableURL = tempRoot.appendingPathComponent(executable)
					guard try archivedApp.extract(relativePath: executable, to: executableURL) else { return }
					let allDylibs = Zsign.listDylibs(appExecutable: executableURL.path).map { $0 as String }
					let visible = allDylibs.filter { $0.hasPrefix("@rpath") || $0.hasPrefix("@executable_path") }
					DispatchQueue.main.async {
						_dylibs = visible
						_hiddenDylibCount = allDylibs.count - visible.count
					}
				} catch {
					print("[ArchiveBacked] Failed to inspect dylibs: \(error)")
				}
			}
			return
		}

		guard let path = Storage.shared.getAppDirectory(for: app) else { return }
		let bundle = Bundle(url: path)
		let execPath = path.appendingPathComponent(bundle?.exec ?? "").relativePath
		let allDylibs = Zsign.listDylibs(appExecutable: execPath).map { $0 as String }
		_dylibs = allDylibs.filter { $0.hasPrefix("@rpath") || $0.hasPrefix("@executable_path") }
		_hiddenDylibCount = allDylibs.count - _dylibs.count
	}
}

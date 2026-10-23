//
//  SigningFrameworksView.swift
//  Feather
//
//  Created by samara on 20.04.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct SigningFrameworksView: View {
	@State private var _frameworks: [String] = []
	@State private var _plugins: [String] = []
	
	private let _frameworksPath: String = .localized("Frameworks")
	private let _pluginsPath: String = .localized("PlugIns")
	
	var app: AppInfoPresentable
	@Binding var options: Options?
	
	// MARK: Body
	var body: some View {
		NBList(.localized("Frameworks & PlugIns")) {
			Group {
				if !_frameworks.isEmpty {
					NBSection(_frameworksPath) {
						ForEach(_frameworks, id: \.self) { framework in
							SigningToggleCellView(
								title: "\(self._frameworksPath)/\(framework)",
								options: $options,
								arrayKeyPath: \.removeFiles
							)
						}
					}
				}
				
				if !_plugins.isEmpty {
					NBSection(_pluginsPath) {
						ForEach(_plugins, id: \.self) { plugin in
							SigningToggleCellView(
								title: "\(self._pluginsPath)/\(plugin)",
								options: $options,
								arrayKeyPath: \.removeFiles
							)
						}
					}
				}
			}
			.disabled(options == nil)
		}
		.onAppear(perform: _listFrameworksAndPlugins)
	}
}

// MARK: - Extension: View
extension SigningFrameworksView {
	private func _listFrameworksAndPlugins() {
		if let archiveURL = Storage.shared.getArchiveURL(for: app),
			let archivedApp = try? ArchiveBackedApp(archiveURL: archiveURL) {
			_frameworks = archivedApp.list(relativePrefix: "Frameworks")
			_plugins = archivedApp.list(relativePrefix: "PlugIns")
			return
		}

		guard let path = Storage.shared.getAppDirectory(for: app) else { return }
		_frameworks = _listFiles(at: path.appendingPathComponent("Frameworks"))
		_plugins = _listFiles(at: path.appendingPathComponent("PlugIns"))
	}
	
	private func _listFiles(at path: URL) -> [String] {
		(try? FileManager.default.contentsOfDirectory(atPath: path.path)) ?? []
	}
}

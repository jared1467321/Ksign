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
        let snapshot = SigningAppSnapshot(app)
        Task { @MainActor in
            let result = try? await BackgroundFileWork.perform { () -> ([String], [String]) in
                if let url = Storage.shared.getArchiveURL(for: snapshot) {
                    let archive = try ArchiveBackedApp(archiveURL: url)
                    return (archive.list(relativePrefix: "Frameworks"), archive.list(relativePrefix: "PlugIns"))
                }
                guard let path = Storage.shared.getAppDirectory(for: snapshot) else { return ([], []) }
                return ((try? FileManager.default.contentsOfDirectory(atPath: path.appendingPathComponent("Frameworks").path)) ?? [],
                        (try? FileManager.default.contentsOfDirectory(atPath: path.appendingPathComponent("PlugIns").path)) ?? [])
            }
            guard !Task.isCancelled, let result else { return }
            _frameworks = result.0
            _plugins = result.1
        }
    }
}

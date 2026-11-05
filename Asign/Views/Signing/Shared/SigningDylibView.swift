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
        let snapshot = SigningAppSnapshot(app)
        Task { @MainActor in
            let result = try? await BackgroundFileWork.perform { () -> ([String], Int) in
                let all: [String]
                if let url = Storage.shared.getArchiveURL(for: snapshot) {
                    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherArchiveDylibInspect_\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: temp) }
                    let archive = try ArchiveBackedApp(archiveURL: url)
                    guard let executable = try archive.metadata().executable, !executable.isEmpty else { return ([], 0) }
                    let file = temp.appendingPathComponent(executable)
                    guard try archive.extract(relativePath: executable, to: file) else { return ([], 0) }
                    all = Zsign.listDylibs(appExecutable: file.path).map { $0 as String }
                } else {
                    guard let path = Storage.shared.getAppDirectory(for: snapshot) else { return ([], 0) }
                    all = Zsign.listDylibs(appExecutable: path.appendingPathComponent(Bundle(url: path)?.exec ?? "").path).map { $0 as String }
                }
                let visible = all.filter { $0.hasPrefix("@rpath") || $0.hasPrefix("@executable_path") }
                return (visible, all.count - visible.count)
            }
            guard !Task.isCancelled, let result else { return }
            _dylibs = result.0
            _hiddenDylibCount = result.1
        }
    }
}

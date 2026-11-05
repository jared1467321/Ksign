//
//  SigningAppAlternativeIconView.swift
//  Feather
//
//  Created by samara on 18.04.2025.
//

import SwiftUI
import NimbleExtensions
import NimbleViews

// MARK: - View
struct SigningAlternativeIconView: View {
	@Environment(\.dismiss) var dismiss
	
	@State private var _alternateIcons: [(name: String, path: String)] = []
	@State private var _archiveIconImages: [String: UIImage] = [:]
	
	var app: AppInfoPresentable
	@Binding var appIcon: UIImage?
	@Binding var isModifing: Bool
	
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Alternative Icons"), displayMode: .inline) {
			List(_alternateIcons, id: \.name) { icon in
				Group {
				Button {
					appIcon = _iconUrl(icon.path)
					dismiss()
				} label: {
					_icon(icon)
				}
				.disabled(!isModifing)
				}
				.nbThemeRow()
			}
			.nbThemeCanvas(rendersAurora: false)
			.onAppear(perform: _loadAlternateIcons)
			.toolbar {
				if isModifing {
					NBToolbarButton(role: .close)
				}
			}
		}
	}
}

// MARK: - Extension: View
extension SigningAlternativeIconView {
	@ViewBuilder
	private func _icon(_ icon: (name: String, path: String)) -> some View {
		HStack(spacing: 12) {
			if let image = _iconUrl(icon.path) {
				Image(uiImage: image)
					.appIconStyle(size: 32)
			}
			
			Text(icon.name)
				.font(.headline)
				.nbThemeForeground(.text)
		}
		.padding(.vertical, 4)
	}
	
	
	private func _iconUrl(_ path: String) -> UIImage? { _archiveIconImages[path] }

    private func _loadAlternateIcons() {
        let snapshot = SigningAppSnapshot(app)
        Task { @MainActor in
            let result = try? await BackgroundFileWork.perform { () -> ([(name: String, path: String)], [String: UIImage]) in
                let archive = try Storage.shared.getArchiveURL(for: snapshot).map { try ArchiveBackedApp(archiveURL: $0) }
                let directory = archive == nil ? Storage.shared.getAppDirectory(for: snapshot) : nil
                let info: [String: Any]?
                if let archive, let data = try archive.data(relativePath: "Info.plist", maximumBytes: 16 * 1024 * 1024) {
                    info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                } else if let directory {
                    info = NSDictionary(contentsOf: directory.appendingPathComponent("Info.plist")) as? [String: Any]
                } else { info = nil }
                guard let icons = info?["CFBundleIcons"] as? [String: Any],
                      let alternates = icons["CFBundleAlternateIcons"] as? [String: [String: Any]] else { return ([], [:]) }
                var rows: [(name: String, path: String)] = []
                var images: [String: UIImage] = [:]
                for (name, details) in alternates {
                    guard let files = details["CFBundleIconFiles"] as? [String], let path = files.first else { continue }
                    rows.append((name, path))
                    if let archive, let data = try? archive.resourceData(named: path, maximumBytes: 32 * 1024 * 1024) {
                        images[path] = UIImage(data: data)?.resizeToSquare()
                    } else if let directory {
                        images[path] = UIImage(contentsOfFile: directory.appendingPathComponent(path).path)?.resizeToSquare()
                    }
                }
                return (rows, images)
            }
            guard !Task.isCancelled, let result else { return }
            _alternateIcons = result.0
            _archiveIconImages = result.1
        }
    }
}

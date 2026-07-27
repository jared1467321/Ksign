//
//  DefaultTweaksView.swift
//  Ksign
//
//  Default signing profile: pick tweaks from the Tweaks folder and toggle
//  them "always inject". Anything enabled here is injected into every app you
//  sign, on top of whatever you add on a specific app's Tweaks screen.
//

import SwiftUI
import NimbleExtensions
import NimbleViews

// MARK: - View
struct DefaultTweaksView: View {
	@State private var _isAddingPresenting = false
	@State private var _tweaksInDirectory: [URL] = []
	@State private var _pendingDeletion: URL?

	@Binding var options: Options

	// The enabled set is stored as bare filenames (e.g. "MyTweak.dylib"),
	// resolved against the Tweaks folder at sign time. Filenames survive an
	// app reinstall; absolute container paths do not.
	private var _enabled: [String] {
		options.defaultInjectionDylibs ?? []
	}

	// MARK: Body
	var body: some View {
		NBList(.localized("Default Tweaks")) {
			if !_tweaksInDirectory.isEmpty {
				NBSection(.localized("Available Tweaks")) {
					ForEach(_tweaksInDirectory, id: \.absoluteString) { tweak in
						_file(tweak: tweak)
					}
				} footer: {
					Text(.localized("Enabled tweaks are injected into every app you sign, in addition to any tweaks you add for a specific app."))
				}
			}
		}
		.overlay(alignment: .center) {
			if _tweaksInDirectory.isEmpty {
				if #available(iOS 17, *) {
					ContentUnavailableView {
						Label(.localized("No Tweaks"), systemImage: "gear.badge.questionmark")
						.foregroundStyle(NBHalloween.heading)
					} description: {
						Text(.localized("Import your .dylib, .deb or .framework files, then toggle the ones you want injected into every app."))
						.foregroundStyle(NBHalloween.textSecondary)
					} actions: {
						Button {
							_isAddingPresenting = true
						} label: {
							Text(.localized("Import")).bg()
						}
					}
				} else {
					Text(.localized("Import your .dylib, .deb or .framework files, then toggle the ones you want injected into every app."))
						.foregroundColor(.secondary)
						.frame(maxWidth: .infinity, alignment: .center)
						.padding()
				}
			}
		}
		.navigationTitle(.localized("Default Tweaks"))
		.toolbar {
			NBToolbarButton(
				systemImage: "plus",
				style: .icon,
				placement: .topBarTrailing
			) {
				_isAddingPresenting = true
			}
		}
		.sheet(isPresented: $_isAddingPresenting) {
			FileImporterRepresentableView(
				allowedContentTypes: [.item],
				allowsMultipleSelection: true,
				onDocumentsPicked: { urls in
					_importTweaks(urls: urls)
				}
			)
		}
		.onAppear(perform: _loadTweaks)
		.confirmationDialog(
			Text(String.localized("Delete Tweak")),
			isPresented: Binding(
				get: { _pendingDeletion != nil },
				set: { if !$0 { _pendingDeletion = nil } }
			),
			titleVisibility: .visible,
			presenting: _pendingDeletion
		) { tweak in
			Button(role: .destructive) {
				_delete(tweak)
			} label: {
				Text(String.localized("Delete"))
			}
			Button(role: .cancel) {
				_pendingDeletion = nil
			} label: {
				Text(String.localized("Cancel"))
			}
		} message: { tweak in
			Text(String.localized(
				"This permanently removes %@ from the Tweaks folder. Apps you sign afterwards can no longer inject it.",
				arguments: tweak.lastPathComponent
			))
		}
	}

	private func _delete(_ tweak: URL) {
		do {
			try FileManager.default.removeItem(at: tweak)
			_setEnabled(false, for: tweak.lastPathComponent)
			_loadTweaks()
		} catch {
			print("Error deleting tweak: \(error)")
		}
		_pendingDeletion = nil
	}

	private func _loadTweaks() {
		let tweaksDir = FileManager.default.tweaks
		guard let files = try? FileManager.default.contentsOfDirectory(
			at: tweaksDir,
			includingPropertiesForKeys: nil
		) else {
			_tweaksInDirectory = []
			return
		}

		_tweaksInDirectory = files.filter { url in
			let ext = url.pathExtension.lowercased()
			return ext == "dylib" || ext == "deb" || ext == "framework" || ext == "bundle"
		}
	}

	private func _importTweaks(urls: [URL]) {
		guard !urls.isEmpty else { return }
		let tweaksDir = FileManager.default.tweaks

		do {
			try FileManager.default.createDirectoryIfNeeded(at: tweaksDir)
		} catch {
			print("Error creating tweaks directory: \(error)")
			return
		}

		let allowedExtensions = Set(["dylib", "deb", "framework", "bundle"])

		for url in urls {
			let ext = url.pathExtension.lowercased()
			guard allowedExtensions.contains(ext) else { continue }

			let destinationURL = tweaksDir.appendingPathComponent(url.lastPathComponent)
			do {
				if FileManager.default.fileExists(atPath: destinationURL.path) {
					try FileManager.default.removeItem(at: destinationURL)
				}
				try FileManager.default.copyItem(at: url, to: destinationURL)
				// Imported here on purpose, so enable it by default.
				_setEnabled(true, for: destinationURL.lastPathComponent)
			} catch {
				print("Error copying tweak file: \(error)")
			}
		}

		_loadTweaks()
	}

	private func _setEnabled(_ isOn: Bool, for name: String) {
		var list = options.defaultInjectionDylibs ?? []
		if isOn {
			if !list.contains(name) { list.append(name) }
		} else {
			list.removeAll { $0 == name }
		}
		options.defaultInjectionDylibs = list
	}
}

// MARK: - Extension: View
extension DefaultTweaksView {
	@ViewBuilder
	private func _file(tweak: URL) -> some View {
		let name = tweak.lastPathComponent

		HStack {
			Text(name)
				.lineLimit(2)
				.frame(maxWidth: .infinity, alignment: .leading)

			Toggle("", isOn: Binding(
				get: { _enabled.contains(name) },
				set: { _setEnabled($0, for: name) }
			))
			.labelsHidden()
		}
		.swipeActions(edge: .trailing, allowsFullSwipe: false) {
			Button(role: .destructive) {
				_pendingDeletion = tweak
			} label: {
				Label(.localized("Delete"), systemImage: "trash")
			}
		}
	}
}

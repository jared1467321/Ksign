//
//  SigningTweaksView.swift
//  Feather
//
//  Created by samara on 20.04.2025.
//
//  Per-app tweak selection for a single signing session.
//
//  One list, one toggle per tweak. Anything in the Default Tweaks profile is
//  already merged into `options.injectionFiles` when the session is created
//  (see Options.mergingDefaultTweaks()), so it shows up here already switched
//  on and can be switched off for *this app only* — the saved default profile
//  is never touched from this screen.
//
//  This screen deliberately has no delete action. `options` here is a throwaway
//  session copy; deleting the file on disk from a per-app screen destroyed the
//  tweak for every app. File management lives in Settings › Default Tweaks.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct SigningTweaksView: View {
	@State private var _isAddingPresenting = false
	@State private var _tweaksInDirectory: [URL] = []
	
	@Binding var options: Options
	
	/// Filenames that belong to the saved Default Tweaks profile.
	private var _defaultNames: Set<String> {
		Set(options.defaultInjectionDylibs ?? [])
	}
	
	/// Filenames enabled for *this* signing session.
	///
	/// Matched by filename rather than full URL on purpose: `injectionFiles`
	/// stores absolute container paths, and those change on reinstall.
	private var _enabledNames: Set<String> {
		Set(options.injectionFiles.map { $0.lastPathComponent })
	}
	
	/// Everything in the Tweaks folder, plus anything already enabled for this
	/// session that isn't in that folder, de-duped by filename and sorted.
	private var _allTweaks: [URL] {
		var seen = Set<String>()
		var result: [URL] = []
		
		for url in _tweaksInDirectory where seen.insert(url.lastPathComponent).inserted {
			result.append(url)
		}
		for url in options.injectionFiles where seen.insert(url.lastPathComponent).inserted {
			result.append(url)
		}
		
		return result.sorted {
			$0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
		}
	}
	
	// MARK: Body
	var body: some View {
		NBList(.localized("Tweaks")) {
			NBSection(.localized("Injection")) {
				Picker(selection: $options.injectPath) {
					ForEach(Options.InjectPath.allCases, id: \.rawValue) { path in
						Text(path.localizedDescription).tag(path)
					}
				} label: {
					Label(.localized("Injection Path"), systemImage: "doc.badge.gearshape")
				}
				Picker(selection: $options.injectFolder) {
					ForEach(Options.InjectFolder.allCases, id: \.rawValue) { folder in
						Text(folder.localizedDescription).tag(folder)
					}
				} label: {
					Label(.localized("Injection Folder"), systemImage: "folder.badge.gearshape")
				}
				Toggle(isOn: $options.injectIntoExtensions) {
					Label(.localized("Inject into Extensions"), systemImage: "syringe")
				}
			}
			
			let tweaks = _allTweaks
			
			if !tweaks.isEmpty {
				NBSection(
					.localized("Tweaks"),
					secondary: "\(_enabledNames.count)/\(tweaks.count)"
				) {
					ForEach(tweaks, id: \.lastPathComponent) { tweak in
						_file(tweak: tweak)
					}
				} footer: {
					Text(.localized("Tweaks from your default profile start switched on. Switching one off here only affects this app — it stays in your defaults."))
				}
			}
		}
		.overlay(alignment: .center) {
			if _allTweaks.isEmpty {
				if #available(iOS 17, *) {
					ContentUnavailableView {
						Label(.localized("No Tweaks"), systemImage: "gear.badge.questionmark")
					} description: {
						Text(.localized("Importing your .dylib, .deb or .framework files \n These will also be automatically added to Tweaks folder"))
					} actions: {
						Button {
							_isAddingPresenting = true
						} label: {
							Text("Import").bg()
						}
					}
				} else {
					Text(.localized("Importing your .dylib, .deb or .framework files \n These will also be automatically added to Tweaks folder"))
						.foregroundColor(.secondary)
						.frame(maxWidth: .infinity, alignment: .center)
						.padding()
				}
			}
		}
		.navigationTitle(.localized("Tweaks"))
		.listStyle(.plain)
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
		
		// Heal stale paths: an enabled tweak whose saved URL no longer exists,
		// but whose filename is sitting in the Tweaks folder, gets repointed at
		// the current container instead of silently failing to inject.
		_rehydrateInjectionPaths()
	}
	
	private func _rehydrateInjectionPaths() {
		let tweaksDir = FileManager.default.tweaks
		
		let healed = options.injectionFiles.map { url -> URL in
			guard !FileManager.default.fileExists(atPath: url.path) else { return url }
			let candidate = tweaksDir.appendingPathComponent(url.lastPathComponent)
			return FileManager.default.fileExists(atPath: candidate.path) ? candidate : url
		}
		
		guard healed != options.injectionFiles else { return }
		options.injectionFiles = healed
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
				// Imported from this screen, so enable it for this session.
				_setEnabled(true, for: destinationURL)
			} catch {
				print("Error copying tweak file: \(error)")
			}
		}
		
		_loadTweaks()
	}
	
	/// Enables/disables a tweak for this signing session only.
	private func _setEnabled(_ isOn: Bool, for tweak: URL) {
		let name = tweak.lastPathComponent
		
		if isOn {
			guard !options.injectionFiles.contains(where: { $0.lastPathComponent == name }) else { return }
			options.injectionFiles.append(_resolved(tweak))
		} else {
			options.injectionFiles.removeAll { $0.lastPathComponent == name }
		}
	}
	
	/// Prefers the copy sitting in the Tweaks folder when one exists.
	private func _resolved(_ tweak: URL) -> URL {
		let candidate = FileManager.default.tweaks.appendingPathComponent(tweak.lastPathComponent)
		return FileManager.default.fileExists(atPath: candidate.path) ? candidate : tweak
	}
}

// MARK: - Extension: View
extension SigningTweaksView {
	@ViewBuilder
	private func _file(tweak: URL) -> some View {
		let name = tweak.lastPathComponent
		let isDefault = _defaultNames.contains(name)
		let isMissing = !FileManager.default.fileExists(atPath: _resolved(tweak).path)
		
		HStack {
			VStack(alignment: .leading, spacing: 2) {
				Text(name)
					.lineLimit(2)
				
				if isMissing {
					Label(.localized("File missing"), systemImage: "exclamationmark.triangle")
						.font(.caption)
						.foregroundStyle(.orange)
				} else if isDefault {
					Text(.localized("Default"))
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			
			Toggle("", isOn: Binding(
				get: { _enabledNames.contains(name) },
				set: { _setEnabled($0, for: tweak) }
			))
			.labelsHidden()
			.disabled(isMissing && !_enabledNames.contains(name))
		}
	}
}

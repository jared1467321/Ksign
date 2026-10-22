//
//  BulkSigningView.swift
//  Ksign
//
//  Created by Nagata Asami on 11/9/25.
//

import SwiftUI
import NimbleExtensions
import NimbleViews
import PhotosUI
import IDeviceSwift

struct AppSignConfig: Identifiable {
    let id: String
    var app: AppInfoPresentable
    var options: Options
    var icon: UIImage?

    init(app: AppInfoPresentable, options: Options, icon: UIImage? = nil) {
        id = app.uuid ?? UUID().uuidString
        self.app = app; self.options = options; self.icon = icon
    }

    func optionsForSigning(certificateRequiresPPQ: Bool) -> Options {
        // Keep explicit identifier edits; derive automatic protection from the
        // current certificate so switching certificates or resetting is safe.
        guard options.ppqProtection, certificateRequiresPPQ,
              options.appIdentifier == nil, let identifier = app.identifier else { return options }
        var resolved = options
        let suffix = ".\(options.ppqString)"
        resolved.appIdentifier = identifier.hasSuffix(suffix) ? identifier : identifier + suffix
        return resolved
    }
}

struct BulkSigningView: View {
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var certificates: FetchedResults<CertificatePair>
	
	private func _selectedCert() -> CertificatePair? {
		guard certificates.indices.contains(_temporaryCertificate) else { return nil }
		return certificates[_temporaryCertificate]
	}
	
	@StateObject private var _optionsManager = OptionsManager.shared
	@State private var _configs: [AppSignConfig]
	@State private var _temporaryCertificate: Int
	@State private var _isAltPickerPresenting = false
	@State private var _isFilePickerPresenting = false
	@State private var _isImagePickerPresenting = false
	@State private var _isSigning = false
	@State private var _selectedPhoto: PhotosPickerItem? = nil
	@State private var _editingConfigId: String?
	
	@Environment(\.dismiss) private var dismiss
	var apps: [AppInfoPresentable]
	// When true, the just-signed apps are handed off for installation
	// once the whole queue finishes.
	var signAndInstall: Bool = false

	init(apps: [AppInfoPresentable], signAndInstall: Bool = false) {
		self.apps = apps
		self.signAndInstall = signAndInstall
		let storedCert = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		__temporaryCertificate = State(initialValue: storedCert)
		
		let defaultOptions = OptionsManager.shared.options.mergingDefaultTweaks()
		__configs = State(initialValue: apps.map { AppSignConfig(app: $0, options: defaultOptions, icon: nil) })
	}

	var body: some View {
		NBNavigationView(.localized("Bulk Signing"), displayMode: .inline) {
			Form {
				Group {
                _cert()
				
				ForEach($_configs) { $config in
					Section {
						_customizationOptions(for: $config)
						_customizationProperties(for: $config)
					}
				}
				}
				.nbThemeRow()
			}
			.nbThemeCanvas(rendersAurora: false)
			.safeAreaInset(edge: .bottom) {
				Button {
					_start()
				} label: {
					NBSheetButton(title: .localized("Start Signing"))
				}
			}
			.toolbar {
				NBToolbarButton(role: .dismiss)
				
				NBToolbarButton(
					.localized("Reset"),
					style: .text,
					placement: .topBarTrailing
				) {
					let defaultOptions = OptionsManager.shared.options.mergingDefaultTweaks()
					for i in _configs.indices {
						_configs[i].options = defaultOptions
						_configs[i].icon = nil
					}
				}
			}
			.sheet(isPresented: $_isAltPickerPresenting) {
				if let id = _editingConfigId, let index = _configs.firstIndex(where: { $0.id == id }) {
					let appBase = _configs[index].app
					let iconBinding = Binding<UIImage?>(
						get: { _configs[index].icon },
						set: { _configs[index].icon = $0 }
					)
					SigningAlternativeIconView(app: appBase, appIcon: iconBinding, isModifing: .constant(true))
				}
			}
			.sheet(isPresented: $_isFilePickerPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes:  [.image],
					onDocumentsPicked: { urls in
						guard let selectedFileURL = urls.first else { return }
						guard let id = _editingConfigId, let index = _configs.firstIndex(where: { $0.id == id }) else { return }
						_configs[index].icon = UIImage.fromFile(selectedFileURL)?.resizeToSquare()
					}
				)
			}
			.photosPicker(isPresented: $_isImagePickerPresenting, selection: $_selectedPhoto)
			.onChange(of: _selectedPhoto) { newValue in
				guard let newValue else { return }
				
				Task { @MainActor in
					if let data = try? await newValue.loadTransferable(type: Data.self),
					   let image = UIImage(data: data)?.resizeToSquare() {
						if let id = _editingConfigId, let index = _configs.firstIndex(where: { $0.id == id }) {
							_configs[index].icon = image
						}
					}
				}
			}
			.disabled(_isSigning)
			.animation(.smooth, value: _isSigning)
		}
	}
}

extension BulkSigningView {
	@ViewBuilder
	private func _customizationOptions(for config: Binding<AppSignConfig>) -> some View {
			let signingOptions = config.wrappedValue.optionsForSigning(certificateRequiresPPQ: _selectedCert()?.ppQCheck == true)
			Menu {
				Button(.localized("Select Alternative Icon")) {
					_editingConfigId = config.wrappedValue.id
					_isAltPickerPresenting = true 
				}
				Button(.localized("Choose from Files")) {
					_editingConfigId = config.wrappedValue.id
					_isFilePickerPresenting = true 
				}
				Button(.localized("Choose from Photos")) {
					_editingConfigId = config.wrappedValue.id
					_isImagePickerPresenting = true 
				}
			} label: {
				if let customIcon = config.icon.wrappedValue {
					Image(uiImage: customIcon)
						.resizable()
						.frame(width: 55, height: 55)
						.cornerRadius(12)
				} else {
					FRAppIconView(app: config.app.wrappedValue, size: 55)
				}
			}
			_infoCell(.localized("Name"), desc: config.options.appName.wrappedValue ?? config.app.wrappedValue.name) {
				SigningPropertiesView(
					title: .localized("Name"),
					initialValue: config.options.appName.wrappedValue ?? (config.app.wrappedValue.name ?? ""),
					bindingValue: config.options.appName
				)
			}
			_infoCell(.localized("Identifier"), desc: signingOptions.appIdentifier ?? config.app.wrappedValue.identifier) {
				SigningPropertiesView(
					title: .localized("Identifier"),
					initialValue: signingOptions.appIdentifier ?? (config.app.wrappedValue.identifier ?? ""),
					bindingValue: config.options.appIdentifier
				)
			}
			_infoCell(.localized("Version"), desc: config.options.appVersion.wrappedValue ?? config.app.wrappedValue.version) {
				SigningPropertiesView(
					title: .localized("Version"),
					initialValue: config.options.appVersion.wrappedValue ?? (config.app.wrappedValue.version ?? ""),
					bindingValue: config.options.appVersion
				)
			}
	}
	

	@ViewBuilder
	private func _cert() -> some View {
		NBSection(.localized("Signing")) {
			if let cert = _selectedCert() {
				NavigationLink {
					CertificatesView(selectedCert: $_temporaryCertificate)
				} label: {
					CertificatesCellView(
						cert: cert
					)
				}
			}
		}
	}
	
	@ViewBuilder
	private func _customizationProperties(for config: Binding<AppSignConfig>) -> some View {
			DisclosureGroup(.localized("Modify")) {
				NavigationLink(.localized("Existing Dylibs")) {
					SigningDylibView(
						app: config.app.wrappedValue,
						options: config.options.optional()
					)
				}
				
				NavigationLink(String.localized("Frameworks & PlugIns")) {
					SigningFrameworksView(
						app: config.app.wrappedValue,
						options: config.options.optional()
					)
				}
				#if NIGHTLY || DEBUG
				NavigationLink(String.localized("Entitlements")) {
					SigningEntitlementsView(
						bindingValue: config.options.appEntitlementsFile
					)
				}
				#endif
				NavigationLink(String.localized("Tweaks")) {
					SigningTweaksView(
						options: config.options
					)
				}
			}
			
			NavigationLink(String.localized("Properties")) {
				Form {
					Group { SigningOptionsView(
					options: config.options,
					temporaryOptions: _optionsManager.options
				)
					}
					.nbThemeRow()
				}
				.nbThemeCanvas()
			.navigationTitle(.localized("Properties"))
		}
	}

	@ViewBuilder
	private func _infoCell<V: View>(_ title: String, desc: String?, @ViewBuilder destination: () -> V) -> some View {
		NavigationLink {
			destination()
		} label: {
			LabeledContent(title) {
				Text(desc ?? .localized("Unknown"))
                    .nbThemeForeground(.textSecondary)
			}
		}
	}

	private func _start() {
		let canSign = _selectedCert() != nil || _configs.allSatisfy { $0.options.doAdhocSigning || $0.options.onlyModify }
		guard canSign else {
			UIAlertController.showAlertWithOk(
				title: .localized("No Certificate"),
				message: .localized("Please go to settings and import a valid certificate"),
				isCancel: true
			)
			return
		}

		_isSigning = true
		let certificate = _selectedCert()
		let configs = _configs.map { config in
			var resolved = config
			resolved.options = config.optionsForSigning(certificateRequiresPPQ: certificate?.ppQCheck == true)
			return resolved
		}
		SigningPreflightCoordinator.review(configs.map { SigningPreflight.source(for: $0.app, options: $0.options) }) { report in
			_runSigning(configs: report.eligibleIndices.map { configs[$0] }, certificate: certificate,
                skipped: report.skipped, archiveApps: report.eligibleIndices.map { report.archiveApps[$0] })
		} onCancel: {
			_isSigning = false
		}
	}

	private func _runSigning(configs: [AppSignConfig], certificate: CertificatePair?, skipped: [SigningPreflight.Issue], archiveApps: [ArchiveBackedApp?]) {
		let generator = UIImpactFeedbackGenerator(style: .light)
		generator.impactOccurred()
		_isSigning = true

        // Read Core Data-backed display/identity fields on the UI context's
        // queue once; worker progress must not fault records during deletion.
        let names = configs.map { $0.app.name ?? .localized("Unknown") }
        let identities = configs.compactMap { $0.app.uuid }
        let sources = archiveApps.compactMap { $0?.archiveURL.standardizedFileURL.path }

		Task.detached(priority: .userInitiated) {
			var failures: [(name: String, error: Error)] = []
			var signedIDs: [String] = []
			var skippedApps = skipped
			var processedCount = skipped.count
			let total = configs.count + skipped.count

			// Seed one stable batch report before the first worker claims signing.
			// Signing has no trustworthy sub-step percentage here, so processed-app
			// count is converted into the aggregate percentage by the task manager.
			BackgroundTaskManager.shared.clearReport(.signing)
			BackgroundTaskManager.shared.claim(.signing)
			BackgroundTaskManager.shared.report(
				.signing,
				completed: processedCount,
				total: total,
				fraction: nil,
				detail: "Signing"
			)

            let context = SigningBatchContext()
            // Duplicate inputs retain serial behavior, including remove-after-sign.
            let unique = identities.count == configs.count && Set(identities).count == identities.count && Set(sources).count == sources.count
            // Workers wait on one process-wide memory governor. It ramps actual
            // admissions every 250 ms when stable, up to five live operations.
            let width = min(unique ? ArchiveMemoryCoordinator.admissionCeiling : 1, configs.count)
            var completedIDs: [Int: String] = [:]
            var indexedFailures: [Int: (String, Error)] = [:]
            await withTaskGroup(of: (Int, Result<String, Error>).self) { group in
                var active = Set(0..<width)
                func reportProgress() {
                    let activeNames = active.sorted().map { names[$0] }.joined(separator: ", ")
                    BackgroundTaskManager.shared.report(.signing, completed: processedCount, total: total,
                        fraction: nil, detail: "Signing", currentItem: activeNames.isEmpty ? nil : activeNames)
                }
                func enqueue(_ index: Int) {
                    let config = configs[index]
                    let archive = archiveApps[index]
                    group.addTask {
                        do { return (index, .success(try await Self._signOne(config, certificate: certificate,
                            archiveApp: archive, batchContext: context))) }
                        catch { return (index, .failure(error)) }
                    }
                }
                for index in 0..<width { enqueue(index) }
                reportProgress()
                var next = width
                while let (index, result) = await group.next() {
                    let currentName = names[index]
                    switch result {
                    case .success(let signedID):
                        completedIDs[index] = signedID
                    case .failure(let error):
                        if let skip = error as? IDeviceInstallSkip {
                            skippedApps.append(.init(name: currentName, reason: skip.reason))
                        } else { indexedFailures[index] = (currentName, error) }
                    }
                    processedCount += 1
                    active.remove(index)
                    if next < configs.count { enqueue(next); active.insert(next); next += 1 }
                    reportProgress()
                }
            }
            signedIDs = configs.indices.compactMap { completedIDs[$0] }
            failures = configs.indices.compactMap { indexedFailures[$0] }

			let handoff = signAndInstall
				? await SigningPreflightCoordinator.prepareInstallation(signedIDs)
				: SigningPreflightCoordinator.Handoff()
			BackgroundTaskManager.shared.report(
				.signing,
				completed: processedCount,
				total: total,
				fraction: nil,
				detail: failures.isEmpty ? (skippedApps.isEmpty && handoff.withheld.isEmpty ? "Completed" : "Finished with Skips") : "Error",
				currentItem: nil
			)
			BackgroundTaskManager.shared.release(.signing, success: failures.isEmpty)

			var sections: [String] = []
			if !skippedApps.isEmpty { sections.append("Skipped before signing:\n" + skippedApps.map(\.description).joined(separator: "\n")) }
			if !failures.isEmpty { sections.append("Signing failed:\n" + failures.map { "\($0.name): \($0.error.localizedDescription)" }.joined(separator: "\n")) }
			if !handoff.withheld.isEmpty { sections.append("Signed, not queued for installation:\n" + handoff.withheld.map(\.description).joined(separator: "\n") + "\n\nThese signed apps remain in Signed Apps.") }
			let summary = sections.joined(separator: "\n\n")

			await MainActor.run {
				_isSigning = false
				let finish = {
					NotificationCenter.default.post(name: NSNotification.Name("ksign.bulkSigningFinished"), object: nil)
					if signAndInstall, !handoff.appIDs.isEmpty {
						DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
							NotificationCenter.default.post(name: NSNotification.Name("ksign.bulkSignAndInstall"), object: handoff.appIDs)
						}
					}
					dismiss()
				}
				if summary.isEmpty { finish() }
				else { UIAlertController.showAlertWithOk(title: "Signing Results", message: summary, action: finish) }
			}
		}
	}

	// Bridges completion independently of UI delivery, including in background.
	private static func _signOne(
		_ config: AppSignConfig,
		certificate: CertificatePair?,
        archiveApp: ArchiveBackedApp?,
        batchContext: SigningBatchContext
	) async throws -> String {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
			FR.signPackageFile(
				config.app,
				using: config.options,
				icon: config.icon,
				certificate: certificate,
                archiveApp: archiveApp,
                batchContext: batchContext,
				backgroundCompletion: { error, signedID in
					if let error {
						continuation.resume(throwing: error)
					} else if let signedID {
						continuation.resume(returning: signedID)
					} else {
						continuation.resume(throwing: ArchiveBackedAppError.invalidArchive)
					}
				}
			) { _, _ in
				// UI completion is intentionally not the batch gate. It may be
				// delivered later when the app is foregrounded.
			}
		}
	}
}

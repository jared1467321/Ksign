//
//  SigningView.swift
//  Feather
//
//  Created by samara on 14.04.2025.
//

import SwiftUI
import NimbleExtensions
import PhotosUI
import NimbleViews
import IDeviceSwift

// MARK: - View
struct SigningView: View {
	@Environment(\.dismiss) var dismiss
	@Namespace var _namespace

	@StateObject private var _optionsManager = OptionsManager.shared
	
	@State private var _temporaryOptions: Options = OptionsManager.shared.options
	@State private var _temporaryCertificate: Int
	@State private var _isAltPickerPresenting = false
	@State private var _isFilePickerPresenting = false
	@State private var _isImagePickerPresenting = false
	@State private var _isLogsPresenting = false
	@State private var _isSigning = false
	@State private var _selectedPhoto: PhotosPickerItem? = nil
	@State var appIcon: UIImage?
	
	var signAndInstall: Bool = false
	
	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var certificates: FetchedResults<CertificatePair>
	
	private func _selectedCert() -> CertificatePair? {
		guard certificates.indices.contains(_temporaryCertificate) else { return nil }
		return certificates[_temporaryCertificate]
	}
	
	private func _getCertAppID() -> String? {
		guard
			let cert = _selectedCert(),
			let decoded = Storage.shared.getProvisionFileDecoded(for: cert),
			let entitlements = decoded.Entitlements,
			let appID = entitlements["application-identifier"]?.value as? String
		else {
			return nil
		}
		return appID.split(separator: ".").dropFirst().joined(separator: ".")
	}
	
	var app: AppInfoPresentable
	
	init(app: AppInfoPresentable, signAndInstall: Bool = false) {
		self.app = app
		self.signAndInstall = signAndInstall
		let storedCert = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		__temporaryCertificate = State(initialValue: storedCert)
		// Start the session with the Default Tweaks profile already applied, so
		// those tweaks show as enabled on the Tweaks screen and are injected.
		__temporaryOptions = State(initialValue: OptionsManager.shared.options.mergingDefaultTweaks())
	}
		
	// MARK: Body
    var body: some View {
		NBNavigationView(app.name ?? .localized("Unknown"), displayMode: .inline, adaptsContainerText: false) {
			Form {
				Group {
				_customizationOptions(for: app)
				_cert()
				_customizationProperties(for: app)
				}
				.nbThemeRow(adaptsText: false)
			}
			// Labels own their adaptive ink so color frames cannot invalidate the form.
			.nbThemeCanvas(rendersAurora: false, adaptsText: false)
			.disabled(_isSigning)
			.safeAreaInset(edge: .bottom) {
				if _isSigning {
					Button() {
						_isLogsPresenting = true
					} label: {
						NBSheetButton(title: .localized("Show Logs"))
					}
					.nbThemeTint(.textSecondary)
					.compatMatchedTransitionSource(id: "showLogs", ns: _namespace)
				} else {
					Button() {
						_start()
					} label: {
						NBSheetButton(title: .localized("Start Signing"))
					}
				}
			}
			.toolbar {
				NBToolbarButton(role: .dismiss)
				
				NBToolbarButton(
					.localized("Reset"),
					style: .text,
					placement: .topBarTrailing
				) {
					_temporaryOptions = OptionsManager.shared.options.mergingDefaultTweaks()
					appIcon = nil
				}
			}
			.sheet(isPresented: $_isAltPickerPresenting) { SigningAlternativeIconView(app: app, appIcon: $appIcon, isModifing: .constant(true)) }
			.sheet(isPresented: $_isFilePickerPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes:  [.image],
					onDocumentsPicked: { urls in
						guard let selectedFileURL = urls.first else { return }
						self.appIcon = UIImage.fromFile(selectedFileURL)?.resizeToSquare()
					}
				)
			}
			.photosPicker(isPresented: $_isImagePickerPresenting, selection: $_selectedPhoto)
			.fullScreenCover(isPresented: $_isLogsPresenting ) {
				LogsView(manager: LogsManager.shared)
					.compatNavigationTransition(id: "showLogs", ns: _namespace)
			}
			.onChange(of: _selectedPhoto) { newValue in
				guard let newValue else { return }
				
				Task {
					if let data = try? await newValue.loadTransferable(type: Data.self),
					   let image = UIImage(data: data)?.resizeToSquare() {
						appIcon = image
					}
				}
			}
			.animation(.smooth, value: _isSigning)
		}
		.onAppear {
			// ppq protection
			if
				_optionsManager.options.ppqProtection,
				let identifier = app.identifier,
				let cert = _selectedCert(),
				cert.ppQCheck
			{
				_temporaryOptions.appIdentifier = "\(identifier).\(_optionsManager.options.ppqString)"
			}
			
			if
				let currentBundleId = app.identifier,
				let newBundleId = _temporaryOptions.identifiers[currentBundleId]
			{
				_temporaryOptions.appIdentifier = newBundleId
			}
			
			if
				let currentName = app.name,
				let newName = _temporaryOptions.displayNames[currentName]
			{
				_temporaryOptions.appName = newName
			}
			
			if _optionsManager.options.prefix != nil || _optionsManager.options.suffix != nil {
				var name = app.name ?? ""
				
				if
					let dictName = _temporaryOptions.displayNames[name]
				{
					name = dictName
				}
				
				if let prefix = _optionsManager.options.prefix {
					name = prefix + name
				}
				
				if let suffix = _optionsManager.options.suffix {
					name = name + suffix
				}
				
				_temporaryOptions.appName = name
			}
		}
    }
}

// MARK: - Extension: View
extension SigningView {
	@ViewBuilder
	private func _customizationOptions(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Customization")) {
			Menu {
				Button(.localized("Select Alternative Icon")) { _isAltPickerPresenting = true }
				Button(.localized("Choose from Files")) { _isFilePickerPresenting = true }
				Button(.localized("Choose from Photos")) { _isImagePickerPresenting = true }
			} label: {
				if let icon = appIcon {
					Image(uiImage: icon)
						.appIconStyle(size: 55)
				} else {
					FRAppIconView(app: app, size: 55)
				}
			}
			
			_infoCell(.localized("Name"), desc: _temporaryOptions.appName ?? app.name) {
				SigningPropertiesView(
					title: .localized("Name"),
					initialValue: _temporaryOptions.appName ?? (app.name ?? ""),
					bindingValue: $_temporaryOptions.appName
				)
			}
			_infoCell(.localized("Identifier"), desc: _temporaryOptions.appIdentifier ?? app.identifier) {
				SigningPropertiesView(
					title: .localized("Identifier"),
					initialValue: _temporaryOptions.appIdentifier ?? (app.identifier ?? ""),
					certAppId: _getCertAppID(),
					bindingValue: $_temporaryOptions.appIdentifier
				)
			}
			_infoCell(.localized("Version"), desc: _temporaryOptions.appVersion ?? app.version) {
				SigningPropertiesView(
					title: .localized("Version"),
					initialValue: _temporaryOptions.appVersion ?? (app.version ?? ""),
					bindingValue: $_temporaryOptions.appVersion
				)
			}
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
	private func _customizationProperties(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Advanced")) {
			DisclosureGroup {
				NavigationLink {
					SigningDylibView(
						app: app,
						options: $_temporaryOptions.optional()
					)
				} label: {
					Text(String.localized("Existing Dylibs"))
						.nbThemeForeground(.text)
				}
				
				NavigationLink {
					SigningFrameworksView(
						app: app,
						options: $_temporaryOptions.optional()
					)
				} label: {
					Text(String.localized("Frameworks & PlugIns"))
						.nbThemeForeground(.text)
				}
				#if NIGHTLY || DEBUG
				NavigationLink {
					SigningEntitlementsView(
						bindingValue: $_temporaryOptions.appEntitlementsFile
					)
				} label: {
					Text(String.localized("Entitlements"))
						.nbThemeForeground(.text)
				}
				#endif
				NavigationLink {
					SigningTweaksView(
						options: $_temporaryOptions
					)
				} label: {
					Text(String.localized("Tweaks"))
						.nbThemeForeground(.text)
				}
			} label: {
				Text(String.localized("Modify"))
					.nbThemeForeground(.text)
			}
			
			NavigationLink {
				Form {
					Group { SigningOptionsView(
					options: $_temporaryOptions,
					temporaryOptions: _optionsManager.options
				)
					}
					.nbThemeRow()
				}
				.nbThemeCanvas()
				.navigationTitle(.localized("Properties"))
			} label: {
				Text(String.localized("Properties"))
					.nbThemeForeground(.text)
			}
		}
	}
	
	@ViewBuilder
	private func _infoCell<V: View>(_ title: String, desc: String?, @ViewBuilder destination: () -> V) -> some View {
		NavigationLink {
			destination()
		} label: {
			LabeledContent {
				Text(desc ?? .localized("Unknown"))
                    .nbThemeForeground(.textSecondary)
			} label: {
				Text(title)
					.nbThemeForeground(.text)
			}
		}
	}
}

// MARK: - Extension: View (import)
extension SigningView {
	private func _start() {
		guard _selectedCert() != nil || _temporaryOptions.doAdhocSigning || _temporaryOptions.onlyModify else {
			UIAlertController.showAlertWithOk(
				title: .localized("No Certificate"),
				message: .localized("Please go to settings and import a valid certificate"),
				isCancel: true
			)
			return
		}

		_isSigning = true
		let options = _temporaryOptions
		let certificate = _selectedCert()
		SigningPreflightCoordinator.review([SigningPreflight.source(for: app, options: options)]) { report in
			_runSigning(options: options, certificate: certificate, archiveApp: report.archiveApps[0])
		} onCancel: {
			_isSigning = false
		}
	}

	private func _runSigning(options: Options, certificate: CertificatePair?, archiveApp: ArchiveBackedApp?) {
		BackgroundTaskManager.shared.begin(.signing)
		let generator = UIImpactFeedbackGenerator(style: .light)
		generator.impactOccurred()
		_isLogsPresenting = _optionsManager.options.signingLogs
		_isSigning = true
#if DEBUG
		LogsManager.shared.startCapture()
#endif
		BackgroundTaskManager.shared.clearReport(.signing)
		BackgroundTaskManager.shared.report(
			.signing,
			completed: 0,
			total: 1,
			fraction: nil,
			detail: "Signing",
			currentItem: app.name
		)

		let signingName = app.name
		let context = SigningBatchContext()
		FR.signPackageFile(
			app,
			using: options,
			icon: appIcon,
			certificate: certificate,
            archiveApp: archiveApp,
            batchContext: context,
			backgroundCompletion: { error, _ in
				BackgroundTaskManager.shared.report(
					.signing,
					completed: 1,
					total: 1,
					fraction: nil,
					detail: error == nil ? "Completed" : (error is IDeviceInstallSkip ? "Finished with Skips" : "Error"),
					currentItem: signingName
				)
			}
		) { [self] error, signedID in
			if let error {
				BackgroundTaskManager.shared.end(.signing, success: error is IDeviceInstallSkip)
				let ok = UIAlertAction(title: .localized("Dismiss"), style: .cancel) { _ in
					dismiss()
				}
				
				UIAlertController.showAlert(
					title: error is IDeviceInstallSkip ? "Signing Skipped" : .localized("Signing"),
					message: [error.localizedDescription, context.patchingReport.summary].compactMap { $0 }.joined(separator: "\n\n"),
					actions: [ok]
				)
			} else {
				Task { @MainActor in
					var notices = [String]()
					let patchingFailure = context.patchingReport.summary
					if let patchingFailure { notices.append(patchingFailure) }
					var installID: String?
					if signAndInstall, let signedID {
						let handoff = await SigningPreflightCoordinator.prepareInstallation([signedID])
						installID = handoff.appIDs.first
						if !handoff.withheld.isEmpty {
							notices.append(handoff.withheld.map(\.description).joined(separator: "\n\n") + "\n\nThe signed app remains in Signed Apps.")
						}
					}
					BackgroundTaskManager.shared.end(.signing, success: true)
					let finish = {
						if let installID {
							DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
								NotificationCenter.default.post(name: NSNotification.Name("feather.installApp"), object: installID)
							}
						}
						dismiss()
					}
					if notices.isEmpty { finish() }
					else {
						UIAlertController.showAlertWithOk(title: patchingFailure == nil ? "Signed · Not Installed" : "Signing Results",
							message: notices.joined(separator: "\n\n"), action: finish)
					}
				}
			}
		}
	}
}

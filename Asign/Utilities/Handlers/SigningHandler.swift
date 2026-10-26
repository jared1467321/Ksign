//
//  SigningHandler.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import Foundation
import Zsign
import UIKit
import OSLog
import ASignArchiveKit

actor SigningStageGate {
    private var occupied = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ operation: () async throws -> T) async rethrows -> T {
        if occupied {
            await withCheckedContinuation { waiting.append($0) }
        } else { occupied = true }
        defer {
            if waiting.isEmpty { occupied = false }
            else { waiting.removeFirst().resume() }
        }
        return try await operation()
    }
}

final class SigningBatchContext {
    let packages = TweakPackageCache()
    let session = ZsignSigningSession()
    let patchingReport = SigningPatchReport()
    private static let memoryWarnings = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
    ) { _ in ArchiveMemoryCoordinator.shared.noteAppMemoryWarning() }

    init() { _ = Self.memoryWarnings }
}

final class SigningHandler: NSObject {
	private let _fileManager = FileManager.default
	private let _workspace: SigningWorkspace
	private var _uuid: String { _workspace.id.uuidString }
	var signedAppID: String { _uuid }
	private var _movedAppPath: URL?
	private var _archiveApp: ArchiveBackedApp?
    private var _archiveResourceDigests: Data?
    private var _archiveTweakWorkspace: ArchiveTweakWorkspace?
	private var _signedArchiveMetadata: ArchiveBackedAppMetadata?
	private var _signedArchiveIcon: String?
	private var _archiveSourceURL: URL?
	private var _archiveRootAppPath: String?
	private var _archiveUsesFullExtractionFallback = false
	private var _archiveOriginalRelativePaths = Set<String>()
	private var _archiveExplicitDeletedPaths = Set<String>()
	private var _archiveSigningHiddenPaths = Set<String>()
	private var _signedArchiveURL: URL?
    private var _published = false
	// using uuid string is the best way to find the
	// app we want to sign, it does not matter what
	// type of app it is
	private var _app: AppInfoPresentable
	private var _options: Options
    private let _packages: TweakPackageCache
    private let _signingSession: ZsignSigningSession?
	private let _uniqueWorkDir: URL
    var memoryCheckpoint: ((String) async throws -> Void)?
    var credentials: SigningCredentials?
    var onPatchingFailure: ((String) -> Void)?
	// the options struct is not gonna decode these so
	// we're just going to do this. If appicon is not
	// specified, we're not going to modify the app
	// icon. If the cert pair is not there, fallback
	// to adhoc signing (if the option is on, otherwise
	// throw an error
	var appIcon: UIImage?
	var appCertificate: CertificatePair?
	
	init(app: AppInfoPresentable, options: Options = OptionsManager.shared.options,
         packages: TweakPackageCache = TweakPackageCache(), signingSession: ZsignSigningSession? = nil) {
		self._app = app
		self._options = options
        self._packages = packages
        self._signingSession = signingSession
        let workspace = SigningWorkspace()
        self._workspace = workspace
		self._uniqueWorkDir = workspace.directory
		super.init()
	}
	
	func copy(archiveApp suppliedArchiveApp: ArchiveBackedApp? = nil) async throws {
		try _workspace.create()

		if let archiveURL = Storage.shared.getArchiveURL(for: _app) {
			let archiveApp = try suppliedArchiveApp ?? ArchiveBackedApp(archiveURL: archiveURL)
            _archiveApp = archiveApp
			_archiveSourceURL = archiveURL
			_archiveRootAppPath = archiveApp.rootAppPath

			let appName = URL(fileURLWithPath: archiveApp.rootAppPath).lastPathComponent
			let movedAppURL = _uniqueWorkDir.appendingPathComponent(appName, isDirectory: true)

            // Canonical archives use a journal of exact tweak destinations.
            // Ambiguous aliases retain complete extraction for source-order compatibility.
			let hasBroadTweakMutations = _options.injectionFiles.contains {
				$0.pathExtension.lowercased() != "dylib"
			} || _options.experiment_replaceSubstrateWithEllekit || _options.ipaPatching == true
            var needsFullTreeForTweaks = false
            if hasBroadTweakMutations {
                var inputs = _options.injectionFiles
                if (!inputs.isEmpty || _options.experiment_replaceSubstrateWithEllekit),
                   (_options.experiment_replaceSubstrateWithEllekit || archiveApp.paths(relativePrefix: "Frameworks/CydiaSubstrate.framework").isEmpty),
                   let loader = Bundle.main.url(forResource: "ellekit", withExtension: "deb") { inputs.append(loader) }
                var mutations = try await TweakHandler.mutationPaths(for: inputs, options: _options, packages: _packages)
                if _options.ipaPatching == true { mutations.formUnion(IPAPatcher.libraryRelativePaths) }
                if let executable = try archiveApp.metadata().executable { mutations.insert(executable) }
                needsFullTreeForTweaks = !archiveApp.supportsSparseTweakMutations(at: mutations)
            }
			if needsFullTreeForTweaks {
				_archiveUsesFullExtractionFallback = true
				_archiveOriginalRelativePaths = Set(archiveApp.paths())
				Logger.signing.notice("[\(self._uuid)] Archive-backed tweak compatibility fallback: materializing full root app tree")
				try archiveApp.extractRootApp(to: movedAppURL)
				guard _fileManager.fileExists(atPath: movedAppURL.path) else {
					throw SigningFileHandlerError.appNotFound
				}
				_movedAppPath = movedAppURL
			} else {
                var hashExclusions = Set(try _options.removeFiles.map(_normalizedArchiveRelativePath))
                hashExclusions.insert("embedded.mobileprovision")
                if _options.ipaPatching == true { hashExclusions.formUnion(IPAPatcher.libraryRelativePaths) }
                if _options.removeWatchPlaceholder { hashExclusions.insert("com.apple.WatchPlaceholder") }
				var removals = Set(try _options.removeFiles.map(_normalizedArchiveRelativePath))
                if _options.removeWatchPlaceholder { removals.insert("com.apple.WatchPlaceholder") }
                // Direct bundles replace their whole destination. Neither old
                // resource hashes nor old executable inputs can survive that edit.
                let replacements = try _options.injectionFiles.filter { $0.pathExtension.lowercased() == "bundle" }
                    .map { try _normalizedArchiveRelativePath($0.lastPathComponent) }
                hashExclusions.formUnion(replacements)
                removals.formUnion(replacements)
				_archiveResourceDigests = try ASignArchive.materializeSigningInputs(
					from: archiveURL,
					rootAppPath: archiveApp.rootAppPath,
					to: movedAppURL,
					includeInfoPlistStrings: _options.appName != nil,
                    index: archiveApp.archiveIndex,
                    hashResources: !_options.onlyModify,
                    excludedResourcePaths: hashExclusions,
                    removedPaths: removals
				)

				_movedAppPath = movedAppURL
			}

			print("[\(_uuid)] Archive-backed signing workspace: \(_movedAppPath?.path ?? "unknown")")
			return
		}

		guard let appUrl = Storage.shared.getAppDirectory(for: _app) else {
			throw SigningFileHandlerError.appNotFound
		}

		let movedAppURL = _uniqueWorkDir.appendingPathComponent(appUrl.lastPathComponent)

		// Legacy filesystem-backed records keep their copy-on-write clone path.
		try _fileManager.cloneItem(at: appUrl, to: movedAppURL)
		_movedAppPath = movedAppURL
		print("[\(_uuid)] Cloned legacy app to: \(movedAppURL.path)")
	}

	func modify(finish: Bool = true) async throws {
		guard let movedAppPath = _movedAppPath else {
			throw SigningFileHandlerError.appNotFound
		}

        try _workspace.sanitize(movedAppPath)
        try await memoryCheckpoint?("before app modifications")
		
		guard
			let infoDictionary = NSDictionary(
				contentsOf: movedAppPath.appendingPathComponent("Info.plist")
			)!.mutableCopy() as? NSMutableDictionary
		else {
			throw SigningFileHandlerError.infoPlistNotFound
		}

        // Capture the ORIGINAL declarations before any signing option edits.
        // This is the same predicate that previously skipped this app outright.
        let platformRejection = SigningPlatformCompatibility.rejectionReason(infoDictionary as? [String: Any] ?? [:])
        // onlyModify can change the root plist before IPAPatcher runs. Capture
        // its original identity now; extensions are still unchanged at patch time.
        let originalBundleIdentifier = (infoDictionary[IPAPatcher.originalIdentifierKey] as? String) ??
            (infoDictionary["CFBundleIdentifier"] as? String)

        // A local SwiftData app can start CloudKit mirroring if re-signing adds
        // the profile's cloud entitlements. Preserve the input's capability
        // policy even with IPA Patching off or if a later injection fails.
        var cloudEntitlementPolicy = !_options.onlyModify && _options.appEntitlementsFile == nil
            ? IPAPatcher.cloudEntitlementPolicy(in: movedAppPath) : [:]
        let compatibilitySnapshots = _options.ipaPatching == true
            ? IPAPatcher.compatibilitySnapshots(in: movedAppPath) : [:]
		
		try await _modifyDict(using: infoDictionary, with: _options, to: movedAppPath)
		
		if let icon = appIcon {
			try await _modifyDict(using: infoDictionary, for: icon, to: movedAppPath)
		}
		
		if let name = _options.appName {
			try await _modifyLocalesForName(name, for: movedAppPath)
		}
		
		if _options.removeWatchPlaceholder {
			try await _removePlaceholderWatch(for: movedAppPath)
		}
		
		if !_options.removeFiles.isEmpty {
			try await _removeFiles(for: movedAppPath, from: _options.removeFiles)
		}
		
        try await _removeCodeSignature(for: movedAppPath)
		try await _removeProvisioning(for: movedAppPath)
		
        // Inject the session's tweak list exactly once. The Default Tweaks
        // profile is already merged into `injectionFiles` when the signing
        // session is created (see Options.mergingDefaultTweaks()), so there's
        // nothing extra to resolve here.
        //
        // Injecting exactly once is deliberate. The previous version called
        // _inject up to twice over the same list, which appended a second
        // LC_LOAD_DYLIB for every dylib — a duplicate load command in the
        // Mach-O. TweakHandler.getInputFiles() runs _checkEllekit() at the top
        // regardless of the list, so the Substrate→ElleKit path is still
        // covered by a single call.
        try await memoryCheckpoint?("before tweak preparation")
        try await _inject(for: movedAppPath, with: _options.injectionFiles, with: _options)
        
        if _options.experiment_supportLiquidGlass {
            try await _locateMachosAndChangeToSDK26(for: movedAppPath)
        }
        
        if #available(iOS 19, *) {
            try await _locateMachosAndFixupArm64eSlice(for: movedAppPath)
        }

        if let platformRejection {
            Logger.signing.notice("[\(self._uuid)] Attempting iOS compatibility: \(platformRejection)")
            try _applyPlatformCompatibility(to: movedAppPath)
        }
		
        try await memoryCheckpoint?("before native signing")
        let archiveContext = _zsignArchiveContext()
        let handler = ZsignHandler(
            appUrl: movedAppPath,
            options: _options,
            cert: appCertificate,
            archiveContext: archiveContext,
            session: _signingSession,
            credentials: credentials
        )
        try await handler.disinject()

        if _options.ipaPatching == true {
            do {
                let patchPolicy = try IPAPatcher.apply(to: movedAppPath, originalRootIdentifier: originalBundleIdentifier,
                    originalSnapshots: compatibilitySnapshots,
                    didRemoveLibrary: { self._archiveExplicitDeletedPaths.insert($0) })
                // Retain the pre-tweak snapshot when both captures succeeded.
                cloudEntitlementPolicy.merge(patchPolicy) { original, _ in original }
            }
            catch let error as IPAPatcher.RecoveryFailure {
                onPatchingFailure?(error.localizedDescription)
                throw error
            }
            catch { onPatchingFailure?(error.localizedDescription) }
        }
		
		if !_options.onlyModify {
			let handler = ZsignHandler(
                appUrl: movedAppPath,
                options: _options,
                cert: appCertificate,
                archiveContext: _zsignArchiveContext(),
                session: _signingSession,
                credentials: credentials,
                cloudEntitlementPolicy: cloudEntitlementPolicy
            )
			
			if _options.doAdhocSigning {
				try await handler.adhocSign()
			} else if (appCertificate != nil) {
				try await handler.sign()
			} else {
				throw SigningFileHandlerError.missingCertifcate
			}
		}
        if finish {
            try await self.move()
            try await self.addToDatabase()
        }

	}
	
	func move() async throws {
		guard let movedAppPath = _movedAppPath else {
			throw SigningFileHandlerError.appNotFound
		}
        try await memoryCheckpoint?("before archive rebuild")

		var destinationURL = try await _directory()
		try _fileManager.createDirectoryIfNeeded(at: destinationURL)

		if let sourceArchive = _archiveSourceURL, let rootAppPath = _archiveRootAppPath {
			let archiveDestination = destinationURL.appendingPathComponent("Archive.ipa", isDirectory: false)
			var finalDeletedPaths = _archiveExplicitDeletedPaths
            if let workspace = _archiveTweakWorkspace { finalDeletedPaths.formUnion(workspace.deletedPaths()) }

			// The tweak compatibility fallback starts from a complete extracted app,
			// and tweak/deb installation may remove arbitrary files without going
			// through SigningHandler's explicit removeFiles option. Record anything
			// that existed in the source archive but is physically gone now so the
			// merge cannot raw-copy a deleted source member back into the signed IPA.
			if _archiveUsesFullExtractionFallback {
				for relativePath in _archiveOriginalRelativePaths {
					let candidate = movedAppPath.appendingPathComponent(relativePath)
					let exists = _fileManager.fileExists(atPath: candidate.path) ||
						((try? _fileManager.destinationOfSymbolicLink(atPath: candidate.path)) != nil)
					if !exists {
						finalDeletedPaths.insert(relativePath)
					}
				}
			}

			// embedded.mobileprovision is removed before signing so the source copy
			// must never leak through. If zsign generated a replacement, the overlay
			// contains it and it is preserved instead of being marked deleted here.
			let finalProvision = movedAppPath.appendingPathComponent("embedded.mobileprovision")
			if !_fileManager.fileExists(atPath: finalProvision.path) {
				finalDeletedPaths.insert("embedded.mobileprovision")
			}

			try ASignArchive.rebuildWithOverlay(
				from: sourceArchive,
				at: archiveDestination,
				rootAppPath: rootAppPath,
				overlayAppURL: movedAppPath,
				deletedPaths: finalDeletedPaths,
				omitExistingCodeSignatures: !_options.onlyModify,
				compression: .none,
                index: _archiveApp?.archiveIndex
			)
            guard let archiveApp = _archiveApp else { throw SigningFileHandlerError.appNotFound }
            let metadata = try archiveApp.metadata(overlayAppURL: movedAppPath, deletedPaths: finalDeletedPaths)
            _signedArchiveIcon = try archiveApp.cachePrimaryIcon(in: destinationURL, overlayAppURL: movedAppPath,
                metadata: metadata, deletedPaths: finalDeletedPaths)
            _signedArchiveMetadata = metadata
			_signedArchiveURL = archiveDestination
			print("[\(_uuid)] Built archive-backed signed IPA: \(archiveDestination.path)")
			try? _fileManager.removeItem(at: _uniqueWorkDir)
			return
		}

		// Legacy filesystem-backed records retain the existing stored .app layout.
		destinationURL = destinationURL.appendingPathComponent(movedAppPath.lastPathComponent)
		try _fileManager.moveItem(at: movedAppPath, to: destinationURL)
		print("[\(_uuid)] Moved App to: \(destinationURL.path)")
		try? _fileManager.removeItem(at: _uniqueWorkDir)
	}

	func addToDatabase() async throws {
		if _signedArchiveURL != nil {
            guard let metadata = _signedArchiveMetadata else { throw SigningFileHandlerError.infoPlistNotFound }
            let cachedIcon = _signedArchiveIcon

			await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
				Storage.shared.addSigned(
					uuid: _uuid,
					certificate: _options.doAdhocSigning ? nil : appCertificate,
					appName: metadata.name,
					appIdentifier: metadata.identifier,
					appVersion: metadata.version,
					appIcon: cachedIcon
				) { _ in
					Logger.signing.info("[\(self._uuid)] Added archive-backed signed app to database")
					continuation.resume()
				}
			}
            _published = true
			return
		}

		let app = try await _directory()
		guard let appUrl = _fileManager.getPath(in: app, for: "app") else {
			throw SigningFileHandlerError.appNotFound
		}

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let bundle = Bundle(url: appUrl)

            Storage.shared.addSigned(
                uuid: _uuid,
                certificate: _options.doAdhocSigning ? nil : appCertificate,
                appName: bundle?.name,
                appIdentifier: bundle?.bundleIdentifier,
                appVersion: bundle?.version,
                appIcon: bundle?.iconFileName
            ) { _ in
                Logger.signing.info("[\(self._uuid)] Added to database")
                continuation.resume()
            }
		}
        _published = true
	}

	private func _zsignArchiveContext() -> ArchiveSigningContext? {
		guard
			!_archiveUsesFullExtractionFallback,
			let archiveURL = _archiveSourceURL,
			let rootAppPath = _archiveRootAppPath
		else {
			return nil
		}

		var deletedPaths = _archiveExplicitDeletedPaths
		deletedPaths.formUnion(_archiveSigningHiddenPaths)
        if let workspace = _archiveTweakWorkspace { deletedPaths.formUnion(workspace.deletedPaths()) }
		return ArchiveSigningContext(
			archiveURL: archiveURL,
			rootAppPath: rootAppPath,
			deletedPaths: deletedPaths,
            manifest: _archiveApp?.archiveIndex.signingManifest,
            resourceDigests: _archiveResourceDigests
		)
	}

	private func _directory() async throws -> URL {
		// Documents/App/Signed/\(UUID)
		_fileManager.signed(_uuid)
	}
	
	func clean() async throws {
        _archiveResourceDigests = nil
        _archiveApp = nil
        _archiveTweakWorkspace = nil
        _archiveOriginalRelativePaths.removeAll()
        _archiveExplicitDeletedPaths.removeAll()
        _archiveSigningHiddenPaths.removeAll()
		try _workspace.clean()
        if !_published {
            try _fileManager.removeFileIfNeeded(at: _fileManager.signed(_uuid))
        }
	}
}

extension SigningHandler {
	private func _modifyDict(using infoDictionary: NSMutableDictionary, with options: Options, to app: URL) async throws {
		if options.fileSharing { infoDictionary.setObject(true, forKey: "UISupportsDocumentBrowser" as NSCopying) }
		if options.itunesFileSharing { infoDictionary.setObject(true, forKey: "UIFileSharingEnabled" as NSCopying) }
		if options.proMotion { infoDictionary.setObject(true, forKey: "CADisableMinimumFrameDurationOnPhone" as NSCopying) }
		if options.gameMode { infoDictionary.setObject(true, forKey: "GCSupportsGameMode" as NSCopying)}
		if options.ipadFullscreen { infoDictionary.setObject(true, forKey: "UIRequiresFullScreen" as NSCopying) }
		if options.removeSupportedDevices { infoDictionary.removeObject(forKey: "UISupportedDevices") }
		if options.removeURLScheme { infoDictionary.removeObject(forKey: "CFBundleURLTypes") }
		if options.experiment_supportLiquidGlass {infoDictionary.removeObject(forKey: "UIDesignRequiresCompatibility") }
		if options.experiment_disableLiquidGlass { infoDictionary.setObject(true, forKey: "UIDesignRequiresCompatibility" as NSCopying) }	
		
		// these are for picker arrays, we check if the default option is named "Default" before applying
		if options.appAppearance != Options.defaultOptions.appAppearance {
			infoDictionary.setObject(options.appAppearance, forKey: "UIUserInterfaceStyle" as NSCopying)
		}
		if options.minimumAppRequirement != Options.defaultOptions.minimumAppRequirement {
			infoDictionary.setObject(options.minimumAppRequirement, forKey: "MinimumOSVersion" as NSCopying)
		}
		
		// this is because only zsign modified these
		if options.onlyModify {
			if let customIdentifier = options.appIdentifier {
				infoDictionary.setObject(customIdentifier, forKey: "CFBundleIdentifier" as NSCopying)
			}
			if let customName = options.appName {
				infoDictionary.setObject(customName, forKey: "CFBundleDisplayName" as NSCopying)
				infoDictionary.setObject(customName, forKey: "CFBundleName" as NSCopying)
			}
			if let customVersion = options.appVersion {
				infoDictionary.setObject(customVersion, forKey: "CFBundleShortVersionString" as NSCopying)
				infoDictionary.setObject(customVersion, forKey: "CFBundleVersion" as NSCopying)
			}
		}
		
		try infoDictionary.write(to: app.appendingPathComponent("Info.plist"))
	}
	
	private func _modifyDict(using infoDictionary: NSMutableDictionary, for image: UIImage, to app: URL) async throws {
		let imageSizes = [
			(width: 120, height: 120, name: "FRIcon60x60@2x.png"),
			(width: 152, height: 152, name: "FRIcon76x76@2x~ipad.png")
		]
		
		for imageSize in imageSizes {
			let resizedImage = image.resize(imageSize.width, imageSize.height)
			let imageData = resizedImage.pngData()
			let fileURL = app.appendingPathComponent(imageSize.name)
			
			try imageData?.write(to: fileURL)
		}
		
		let cfBundleIcons: [String: Any] = [
			"CFBundlePrimaryIcon": [
				"CFBundleIconFiles": ["FRIcon60x60"],
				"CFBundleIconName": "FRIcon"
			]
		]
		
		let cfBundleIconsIpad: [String: Any] = [
			"CFBundlePrimaryIcon": [
				"CFBundleIconFiles": ["FRIcon60x60", "FRIcon76x76"],
				"CFBundleIconName": "FRIcon"
			]
		]
		
		infoDictionary["CFBundleIcons"] = cfBundleIcons
		infoDictionary["CFBundleIcons~ipad"] = cfBundleIconsIpad
		
		try infoDictionary.write(to: app.appendingPathComponent("Info.plist"))
	}
	
	private func _removePlaceholderWatch(for app: URL) async throws {
		let relativePath = "com.apple.WatchPlaceholder"
		if _archiveSourceURL != nil {
			_archiveExplicitDeletedPaths.insert(relativePath)
		}
		let path = app.appendingPathComponent(relativePath)
		try _fileManager.removeFileIfNeeded(at: path)
	}
	
	private func _removeFiles(for app: URL, from appendingComponent: [String]) async throws {
		for component in appendingComponent {
			let normalized = try _normalizedArchiveRelativePath(component)
			if _archiveSourceURL != nil {
				_archiveExplicitDeletedPaths.insert(normalized)
			}
			try _fileManager.removeFileIfNeeded(at: app.appendingPathComponent(normalized))
		}
	}

	private func _normalizedArchiveRelativePath(_ path: String) throws -> String {
		let slashNormalized = path.replacingOccurrences(of: "\\", with: "/")
		let normalized = slashNormalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
		guard
			!normalized.isEmpty,
			!slashNormalized.hasPrefix("/"),
			!normalized.contains("\n"),
			!normalized.contains("\r"),
			!components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
		else {
			throw SigningFileHandlerError.unsafeRemovalPath(path)
		}
		return normalized
	}

	private func _modifyLocalesForName(_ name: String, for app: URL) async throws {
		let localizationBundles = try _fileManager
			.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
			.filter { $0.pathExtension == "lproj" }
		
		localizationBundles.forEach { bundleURL in
			let plistURL = bundleURL.appendingPathComponent("InfoPlist.strings")
			
			guard
				_fileManager.fileExists(atPath: plistURL.path),
				let dictionary = NSMutableDictionary(contentsOf: plistURL)
			else {
				return
			}
			
			dictionary["CFBundleDisplayName"] = name
			dictionary.write(toFile: plistURL.path, atomically: true)
		}
	}
    
    private func _removeCodeSignature(for app: URL) async throws {
        // Normal archive-backed signing drops every source CodeSignature during
        // the merge and lets zsign append regenerated signatures from the overlay.
        // onlyModify preserves nested signatures like the legacy filesystem path,
        // but the root signature is still explicitly removed by this operation.
        if _archiveSourceURL != nil && _options.onlyModify {
            _archiveExplicitDeletedPaths.insert("_CodeSignature")
        }

        let provisioningFilePath = app.appendingPathComponent("_CodeSignature")
        try _fileManager.removeFileIfNeeded(at: provisioningFilePath)
    }
	
	private func _removeProvisioning(for app: URL) async throws {
		let relativePath = "embedded.mobileprovision"
		if _archiveSourceURL != nil {
			_archiveSigningHiddenPaths.insert(relativePath)
		}
		let provisioningFilePath = app.appendingPathComponent(relativePath)
		try _fileManager.removeFileIfNeeded(at: provisioningFilePath)
	}

	private func _inject(for app: URL, with tweaks: [URL], with options: Options) async throws {
        let workspace: ArchiveTweakWorkspace?
        if let archive = _archiveApp, !_archiveUsesFullExtractionFallback {
            workspace = ArchiveTweakWorkspace(archive: archive, appURL: app,
                excluded: _archiveExplicitDeletedPaths.union(_archiveSigningHiddenPaths))
        } else { workspace = nil }
        let handler = TweakHandler(app: app, with: tweaks, options: options,
            prepareDestination: workspace.map { workspace in
                { path, replacing in try workspace.prepare(path, replacing: replacing) }
            }, packages: _packages, validateWorkspace: { try self._workspace.sanitizeAdditions($0) })
		do {
			try await handler.getInputFiles()
            _archiveTweakWorkspace = workspace
		} catch {
			throw error
		}
	}

    private func _locateMachosAndChangeToSDK26(for app: URL) async throws {
        if let url = Bundle(url: app)?.executableURL {
            LCPatchMachOForSDK26(app.appendingPathComponent(url.relativePath).relativePath)
        }
    }

    private func _applyPlatformCompatibility(to app: URL) throws {
        let target = SigningPlatformCompatibility.Target(system: ProcessInfo.processInfo.operatingSystemVersion,
            minimumOverride: _options.minimumAppRequirement)
        Logger.signing.notice("[\(self._uuid)] iOS compatibility minimum: \(target.version); SDK metadata: \(target.sdkVersion)")
        var enumerationError: Error?
        guard let entries = _fileManager.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw SigningFileHandlerError.appNotFound
        }
        var plists: [URL] = []
        var patchedBinaries = Set<URL>()
        // Archive-backed signing has already materialized every Mach-O and
        // Info.plist. Resources remain compressed; no full extraction is needed.
        for case let file as URL in entries {
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if file.lastPathComponent == "Info.plist" { plists.append(file); continue }
            if attributes.isSymbolicLink == true { entries.skipDescendants(); continue }
            guard attributes.isRegularFile == true else { continue }
            var changed: UInt = 0
            if let error = KsignPatchMachOForIOS(file.path, target.minimumOS, target.sdk, &changed) {
                throw SigningPlatformCompatibility.Failure.patch(error)
            }
            if changed > 0 {
                patchedBinaries.insert(file.resolvingSymlinksInPath().standardizedFileURL)
                Logger.signing.notice("[\(self._uuid)] iOS compatibility patched \(changed) slice(s): \(file.lastPathComponent)")
            }
        }
        if let enumerationError { throw enumerationError }
        for plist in plists {
            var format = PropertyListSerialization.PropertyListFormat.xml
            let data = try Data(contentsOf: plist)
            guard var info = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
            else { continue }
            let isRoot = plist.standardizedFileURL == app.appendingPathComponent("Info.plist").standardizedFileURL
            guard let bundle = SigningPlatformCompatibility.codeBundle(containing: plist, inside: app) else { continue }
            let executable = info["CFBundleExecutable"] as? String
            let patchedExecutable = executable.map {
                patchedBinaries.contains(bundle.appendingPathComponent($0).resolvingSymlinksInPath().standardizedFileURL)
            } ?? false
            // An already-iOS extension/framework can still carry a newer OS
            // requirement. Normalize it only inside an activated shim tree.
            guard SigningPlatformCompatibility.shouldNormalize(info, target: target,
                isRoot: isRoot, executableWasPatched: patchedExecutable) else { continue }
            SigningPlatformCompatibility.normalize(&info, target: target,
                isApplication: isRoot || bundle.pathExtension == "app" || bundle.pathExtension == "appex")
            let patched = try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0)
            try patched.write(to: plist, options: .atomic)
        }
    }
    
    @available(iOS 19, *)
    private func _locateMachosAndFixupArm64eSlice(for app: URL) async throws {
        let machoFiles = _enumerateFiles(at: app) {
            $0.hasSuffix(".dylib") || $0.hasSuffix(".framework")
        }
        
        for fileURL in machoFiles {
            switch fileURL.pathExtension {
            case "dylib":
                LCPatchMachOFixupARM64eSlice(fileURL.path)
            case "framework":
                if
                    let bundle = Bundle(url: fileURL),
                    let execURL = bundle.executableURL
                {
                    LCPatchMachOFixupARM64eSlice(execURL.path)
                }
            default:
                continue
            }
        }
    }
    
    private func _enumerateFiles(at base: URL, where predicate: (String) -> Bool) -> [URL] {
        guard let fileEnum = _fileManager.enumerator(atPath: base.path) else {
            return []
        }
        
        var results: [URL] = []
        
        while let file = fileEnum.nextObject() as? String {
            if predicate(file) {
                results.append(base.appendingPathComponent(file))
            }
        }
        
        return results
    }
}

enum SigningFileHandlerError: Error, LocalizedError {
	case appNotFound
	case infoPlistNotFound
	case missingCertifcate
	case disinjectFailed
	case signFailed
	case unsafeRemovalPath(String)
	
	var errorDescription: String? {
		switch self {
		case .appNotFound:
			return "Unable to locate bundle path."
		case .infoPlistNotFound:
			return "Unable to locate info.plist path."
		case .missingCertifcate:
			return "No certificate was specified."
		case .disinjectFailed:
			return "Removing mach-O load paths failed."
		case .signFailed:
			return "Signing failed."
		case .unsafeRemovalPath(let path):
			return "Refusing to remove an unsafe app-relative path: \(path)"
		}
	}
}

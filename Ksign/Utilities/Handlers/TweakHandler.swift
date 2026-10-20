//
//  DylibHandler.swift
//  feather
//
//  Created by samara on 8/17/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import Foundation
import Zsign
import OSLog

// The owner is one signing operation/batch. Prepared packages are read-only;
// injection always copies their files before patching any load commands.
actor TweakPackageCache {
    // A compressed deb can expand far beyond its file size. Coalescing shared
    // packages avoids duplicate work; this process-wide gate also prevents
    // unrelated batches decoding several unbounded in-memory payloads together.
    private static let decoding = SigningStageGate()
    private struct Identity: Hashable {
        let path: String
        let size: UInt64
        let modified: Date?
        let created: Date?
        let inode: UInt64
    }
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherPreparedTweaks_" + UUID().uuidString)
    private var packages: [Identity: Task<[URL], Error>] = [:]
    deinit { try? FileManager.default.removeItem(at: directory) }

    func roots(for url: URL) async throws -> [URL] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let key = Identity(path: url.standardizedFileURL.resolvingSymlinksInPath().path,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: attributes[.modificationDate] as? Date, created: attributes[.creationDate] as? Date,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
        if let existing = packages[key] { return try await existing.value }
        let destination = directory.appendingPathComponent(UUID().uuidString)
        let task = Task.detached { () throws -> [URL] in
            try await Self.decoding.run {
                do {
                    var roots: [URL] = []
                    let members = try await AR(with: url).extract()
                    for member in members where ["data.tar", "data.tar.lzma", "data.tar.gz", "data.tar.xz", "data.tar.bz2"].contains(member.name) {
                        let root = destination.appendingPathComponent(UUID().uuidString)
                        try autoreleasepool { try extractDebPayload(member.content, name: member.name, to: root) }
                        roots.append(root)
                    }
                    return roots
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    throw error
                }
            }
        }
        packages[key] = task
        do { return try await task.value }
        catch { packages.removeValue(forKey: key); throw error }
    }
}

class TweakHandler {
    static func mutationPaths(for urls: [URL], options: Options, packages: TweakPackageCache) async throws -> Set<String> {
        var paths: Set<String> = ["Frameworks/CydiaSubstrate.framework"]
        if options.injectIntoExtensions { paths.formUnion(["PlugIns", "Extensions"]) }
        func add(_ url: URL) {
            switch url.pathExtension.lowercased() {
            case "framework": paths.insert("Frameworks/" + url.lastPathComponent)
            case "bundle": paths.insert(url.lastPathComponent)
            case "dylib": paths.insert((options.injectFolder == .frameworks ? "Frameworks/" : "") + url.lastPathComponent)
            default: break
            }
        }
        for url in urls {
            if url.pathExtension.lowercased() != "deb" { add(url); continue }
            for root in try await packages.roots(for: url) {
                guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
                for case let candidate as URL in entries {
                    if (try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
                        entries.skipDescendants(); continue
                    }
                    add(candidate)
                    if ["framework", "bundle"].contains(candidate.pathExtension.lowercased()) { entries.skipDescendants() }
                }
            }
        }
        return paths
    }
	private let _fileManager = FileManager.default
	private var _urlsToInject: [URL] = []
	private var _directoriesToCheck: [URL] = []
    private var _injectedDylibNames: [String] = []

	private var _urls: [URL]
	private let _app: URL
    private var _options: Options
    private let _prepareDestination: ((String, Bool) throws -> Void)?
    private let _packages: TweakPackageCache
    private let _validateWorkspace: (() throws -> Void)?
    private lazy var _mainExecutable = Bundle(url: _app)?.executableURL
    private struct MachOPatch {
        var rewrites: [String: String] = [:]
        var injections: [String] = []
    }
    private var _patches: [URL: MachOPatch] = [:]
    private var _patchOrder: [URL] = []

    private func _queuePatch(for executable: URL, rewriteSubstrate: Bool = false, injection: String? = nil) {
        let executable = executable.resolvingSymlinksInPath().standardizedFileURL
        if _patches[executable] == nil { _patchOrder.append(executable) }
        var patch = _patches[executable] ?? MachOPatch()
        if rewriteSubstrate {
            patch.rewrites["/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"] = "@rpath/CydiaSubstrate.framework/CydiaSubstrate"
        }
        if let injection { patch.injections.append(injection) }
        _patches[executable] = patch
    }

    private func _applyPatches() {
        for executable in _patchOrder {
            guard let patch = _patches[executable] else { continue }
            let success = Zsign.patchDylibs(appExecutable: executable.path, rewrites: patch.rewrites, injections: patch.injections)
            if !success { Logger.misc.warning("One or more load-command edits failed for \(executable.lastPathComponent)") }
        }
        _patches.removeAll(); _patchOrder.removeAll()
    }
    
    init(app: URL, with urls: [URL], options: Options = OptionsManager.shared.options,
         prepareDestination: ((String, Bool) throws -> Void)? = nil,
         packages: TweakPackageCache = TweakPackageCache(),
         validateWorkspace: (() throws -> Void)? = nil) {
		self._app = app
		self._urls = urls
        self._options = options
        self._prepareDestination = prepareDestination
        self._packages = packages
        self._validateWorkspace = validateWorkspace
	}
    
    private func _checkEllekit() async throws {
        if !_urls.isEmpty || _options.experiment_replaceSubstrateWithEllekit {
            try _prepareDestination?("Frameworks/CydiaSubstrate.framework", false)
        }
        let frameworksPath = _app.appendingPathComponent("Frameworks").appendingPathComponent("CydiaSubstrate.framework")

        func addEllekit() async throws {
            if let ellekitURL = Bundle.main.url(forResource: "ellekit", withExtension: "deb") {
                self._urls.insert(ellekitURL, at: 0)
            } else {
                print("ellekit.deb not found in the app bundle")
            }
            
            try _fileManager.createDirectoryIfNeeded(at: _app.appendingPathComponent("Frameworks"))
        }
        // we should check if CydiaSubstrate.framework exists, if it doesn't
        // just add ellekit
        // experiment_replaceSubstrateWithEllekit:
        //     for this version, we need to replace CydiaSubstrate.framework with
        //    our own version containing ElleKit
        // other:
        //     just return if it exists, should work fine
        if _fileManager.fileExists(atPath: frameworksPath.path) {
            if _options.experiment_replaceSubstrateWithEllekit {
                print("Attempting to replace Substrate with ElleKit")
                try _fileManager.removeFileIfNeeded(at: frameworksPath)
                try await addEllekit()
            } else {
                return
            }
        } else {
            guard !_urls.isEmpty else { return }
            try await addEllekit()
        }
    }

	public func getInputFiles() async throws {
        try await _checkEllekit()
        
		if _urls.isEmpty {
			return
		}
		
		let frameworksDir = _app.appendingPathComponent("Frameworks")
		try _fileManager.createDirectoryIfNeeded(at: frameworksDir)
		
		// check for appropriate files, if theres debs
		// it will extract then add a url, if theres no url, i.e.
		// you haven't added a deb, it will skip
		for url in _urls {
			switch url.pathExtension.lowercased() {
			case "dylib":
				try await _handleDylib(at: url)
			case "deb":
				_directoriesToCheck.append(contentsOf: try await _packages.roots(for: url))
			case "framework":
				try await _handleFramework(at: url)
			case "bundle":
				try await _handleBundle(at: url)
			default:
				print("Unsupported file type: \(url.lastPathComponent), skipping.")
			}
		}
		
		// check contents of data.tar's extracted from debs
		if !_directoriesToCheck.isEmpty {
			try await _handleDirectories(at: _directoriesToCheck)
			if !_urlsToInject.isEmpty {
				try await _handleExtractedDirectoryContents(at: _urlsToInject)
			}
		}

		// inject into all extensions if enabled
		if _options.injectIntoExtensions && !_injectedDylibNames.isEmpty {
			_injectIntoAllExtensions(dylibNames: _injectedDylibNames)
		}
        // Imported frameworks can contain symlinks. Validate all destinations
        // before applying any queued edits, including paths resolved above.
        try _validateWorkspace?()
        _applyPatches()
	}
	
	// finally, handle extracted contents
	private func _handleExtractedDirectoryContents(at urls: [URL]) async throws {
		for url in urls {
			switch url.pathExtension.lowercased() {
			case "dylib":
				try await _handleDylib(at: url)
			case "framework":
				try await _handleFramework(at: url)
			case "bundle":
                try _prepareDestination?(url.lastPathComponent, false)
				let destinationURL = _app.appendingPathComponent(url.lastPathComponent)
				
				// Use copyItem instead of moveFileIfNeeded to preserve the original file
				if !_fileManager.fileExists(atPath: destinationURL.path) {
					try _fileManager.copyItem(at: url, to: destinationURL)
				}
			default:
				print("Unsupported file type: \(url.lastPathComponent), skipping.")
			}
		}
	}
	
	// Inject imported dylib file
	private func _handleDylib(at url: URL) async throws {
		var destinationURL = _app
		var injectFolder = _options.injectFolder

		// check for "/Frameworks/", then append the destinationUrl
		if _options.injectFolder == .frameworks {
			destinationURL = destinationURL.appendingPathComponent("Frameworks")
		}

		// We check for "@rpath" and "/Frameworks/", if they're both enabled force
		// the inject folder to be root "/" instead, as the @rpath is already in
		// frameworks
		if
			_options.injectPath == .rpath && _options.injectFolder == .frameworks
		{
			injectFolder = .root
		}

		destinationURL = destinationURL.appendingPathComponent(url.lastPathComponent)
        let relative = (_options.injectFolder == .frameworks ? "Frameworks/" : "") + url.lastPathComponent
        try _prepareDestination?(relative, false)

		if !_fileManager.fileExists(atPath: destinationURL.path) {
			try _fileManager.copyItem(at: url, to: destinationURL)
		}
		
		guard let appexe = _mainExecutable else {
			return
		}
		
		// change paths because some tweaks hardlink, which is not ideal.
		// this is not a good solution, at most this would work for basic tweaks
		// we recommend you use newer theos to compile, and make sure it works
		// using the ellekit framework
		_queuePatch(for: destinationURL, rewriteSubstrate: true)
        _queuePatch(for: appexe, injection: "\(_options.injectPath.rawValue)\(injectFolder.rawValue)\(destinationURL.lastPathComponent)")

		_injectedDylibNames.append(destinationURL.lastPathComponent)
	}
	

	private func _handleFramework(at url: URL) async throws {
        try _prepareDestination?("Frameworks/" + url.lastPathComponent, false)
		let destinationURL = _app.appendingPathComponent("Frameworks").appendingPathComponent(url.lastPathComponent)

		if !_fileManager.fileExists(atPath: destinationURL.path) {
			try _fileManager.copyItem(at: url, to: destinationURL)
		}
		
		guard
			let fexe = Bundle(url: destinationURL)?.executableURL,
			let appexe = _mainExecutable
		else {
			print("Error: Could not find executable in framework or app bundle")
			return
		}
		
		// change paths because some tweaks hardlink, which is not ideal.
		// this is not a good solution, at most this would work for basic tweaks
		// I recommend you use newer theos to compile, and make sure it works
		// using the ellekit framework
		_queuePatch(for: fexe, rewriteSubstrate: true)
        _queuePatch(for: appexe, injection: "@executable_path/Frameworks/\(destinationURL.lastPathComponent)/\(fexe.lastPathComponent)")
	}

	private func _handleBundle(at url: URL) async throws {
        try _prepareDestination?(url.lastPathComponent, true)
		let destinationURL = _app.appendingPathComponent(url.lastPathComponent)

		if _fileManager.fileExists(atPath: destinationURL.path) {
			try _fileManager.removeItem(at: destinationURL)
		}
		try _fileManager.copyItem(at: url, to: destinationURL)
	}
	
	// Read extracted deb file, locate all neccessary contents to copy over to the .app
	private func _handleDirectories(at urls: [URL]) async throws {
		enum DirectoryType: String {
			case frameworks = "Frameworks"
			case dynamicLibraries = "MobileSubstrate/DynamicLibraries"
			case applicationSupport = "Application Support"
		}
		
		let directoryPaths: [DirectoryType: [String]] = [
			.frameworks: ["Library/Frameworks/", "var/jb/Library/Frameworks/"],
			.dynamicLibraries: ["Library/MobileSubstrate/DynamicLibraries/", "var/jb/Library/MobileSubstrate/DynamicLibraries/"],
			.applicationSupport: ["Library/Application Support/", "var/jb/Library/Application Support/"]
		]
				
		for baseURL in urls {
			for (directoryType, paths) in directoryPaths {
				for path in paths {
					let directoryURL = baseURL.appendingPathComponent(path)
					
					guard _fileManager.fileExists(atPath: directoryURL.path) else {
						print("Directory does not exist: \(directoryURL.path). Skipping.")
						continue
					}
					
					switch directoryType {
					case .dynamicLibraries:
						let dylibFiles = try await _locateDylibFiles(in: directoryURL)
						_urlsToInject.append(contentsOf: dylibFiles)
						
					case .frameworks:
						let frameworkDirectories = try await _locateFrameworkDirectories(in: directoryURL)
						_urlsToInject.append(contentsOf: frameworkDirectories)
						
					case .applicationSupport:
						try await _searchForBundles(in: directoryURL)
					}
				}
			}
		}
	}
}

// MARK: - Find correct files in debs
extension TweakHandler {
	private func _searchForBundles(in directory: URL) async throws {
		let fileManager = FileManager.default
		let allFiles = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

		let bundleDirectories = allFiles.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "bundle" && url.hasDirectoryPath && !isSymlink
		}
		
		for bundleURL in bundleDirectories {
			_urlsToInject.append(bundleURL)
		}
		
		let directoriesToSearch = allFiles.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.hasDirectoryPath && !bundleDirectories.contains(url) && !isSymlink
		}
		
		for dirURL in directoriesToSearch {
			try await _searchForBundles(in: dirURL)
		}
	}

	private func _locateDylibFiles(in directory: URL) async throws -> [URL] {
		let fileManager = FileManager.default
		let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])

		let dylibFiles = files.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "dylib" && !isSymlink
		}
		
		return dylibFiles
	}

	private func _locateFrameworkDirectories(in directory: URL) async throws -> [URL] {
		let fileManager = FileManager.default
		let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

		let frameworkDirectories = files.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "framework" && url.hasDirectoryPath && !isSymlink
		}
		
		return frameworkDirectories
	}

	// Discovers all .appex bundles in the app's PlugIns and Extensions directories
	private func _discoverAppExtensions() -> [URL] {
		var extensions: [URL] = []
		
		let plugInsPath = _app.appendingPathComponent("PlugIns")
		let extensionsPath = _app.appendingPathComponent("Extensions")
		
		for directory in [plugInsPath, extensionsPath] {
			guard _fileManager.fileExists(atPath: directory.path) else { continue }
			
			do {
				let contents = try _fileManager.contentsOfDirectory(
					at: directory,
					includingPropertiesForKeys: nil,
					options: [.skipsHiddenFiles]
				)
				
				let appexBundles = contents.filter { url in
					url.pathExtension.lowercased() == "appex" && url.hasDirectoryPath
				}
				
				extensions.append(contentsOf: appexBundles)
			} catch {
				Logger.misc.warning("Failed to enumerate \(directory.path): \(error.localizedDescription)")
			}
		}
		
		return extensions
	}

	// Injects a dylib into an extension's executable
	private func _injectIntoExtension(extensionURL: URL, dylibNames: [String]) {
		guard 
			let extensionBundle = Bundle(url: extensionURL),
			let extensionExecutable = extensionBundle.executableURL 
		else {
			Logger.misc.warning("Skipping \(extensionURL.lastPathComponent): couldn't read bundle")
			return
		}
		
		var injectFolder = _options.injectFolder
		if _options.injectPath == .rpath && _options.injectFolder == .frameworks {
			injectFolder = .root
		}
		
        for dylibName in dylibNames {
		let injectPath: String
		if _options.injectPath == .rpath {
			injectPath = "@rpath/\(dylibName)"
		} else if injectFolder == .frameworks {
			injectPath = "@executable_path/../../Frameworks/\(dylibName)"
		} else {
			injectPath = "@executable_path/../../\(dylibName)"
		}
		
        _queuePatch(for: extensionExecutable, injection: injectPath)
        }
    }

	// Injects all dylibs into all discovered extensions
	private func _injectIntoAllExtensions(dylibNames: [String]) {
		let extensions = _discoverAppExtensions()

		guard !extensions.isEmpty else {
			Logger.misc.info("No app extensions found for injection")
			return
		}

		Logger.misc.info("Found \(extensions.count) app extension(s) for injection")

		for extensionURL in extensions {
            _injectIntoExtension(extensionURL: extensionURL, dylibNames: dylibNames)
		}
	}
}

enum TweakHandlerError: Error {
	case unsupportedFileExtension(String)
	case decompressionFailed(String)
	case missingFile(String)
	case noAccess
}

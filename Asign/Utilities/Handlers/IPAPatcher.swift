import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A patch attempt belongs to one private signing workspace. Prepare every
/// executable before publishing any changes; never sign a half-patched app.
enum IPAPatcher {
    static let libraryName = "blatantsPatch.dylib"
    static let libraryRelativePath = "Frameworks/" + libraryName
    static let identityLibraryName = "asignIdentity.dylib"
    static let identityLibraryRelativePath = "Frameworks/" + identityLibraryName
    static let libraryRelativePaths: Set<String> = [libraryRelativePath, identityLibraryRelativePath]
    static let originalIdentifierKey = "AsignOriginalBundleIdentifier"

    struct Target {
        let executable: URL
        let loadPath: String
        let infoPlist: URL
    }

    private final class RunpathResolver {
        let root: URL
        let executableDirectory: URL
        let library: URL

        init(root: URL, executable: URL, library: URL) {
            self.root = root
            executableDirectory = executable.deletingLastPathComponent()
            self.library = library
        }

        func resolve(_ runpath: String) -> Int32 {
            let prefixes = ["@loader_path", "@executable_path"]
            guard let prefix = prefixes.first(where: { runpath == $0 || runpath.hasPrefix($0 + "/") }) else {
                return -1 // Its runtime location cannot be verified here.
            }
            let suffix = String(runpath.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let candidate = executableDirectory.appendingPathComponent(suffix, isDirectory: true)
                .appendingPathComponent(library.lastPathComponent)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard candidate.path.hasPrefix(root.path + "/") else { return -1 }
            if candidate.path == library.path { return 1 }
            // An earlier extension-local copy would shadow the app's patch.
            let manager = FileManager.default
            if manager.fileExists(atPath: candidate.path) ||
               (try? manager.destinationOfSymbolicLink(atPath: candidate.path)) != nil { return -1 }
            return 0
        }
    }

    struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    // A rollback failure is an actual workspace I/O failure, rather than a
    // patch incompatibility. Do not hand damaged inputs to the native signer.
    struct RecoveryFailure: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    static func targets(in app: URL) throws -> [Target] {
        let manager = FileManager.default
        let root = app.resolvingSymlinksInPath().standardizedFileURL
        let library = root.appendingPathComponent(libraryRelativePath).resolvingSymlinksInPath()
        try requireInside(library, root: root)
        var plists = [root.appendingPathComponent("Info.plist")]
        var enumerationError: Error?
        guard let entries = manager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw Failure(detail: "Cannot discover app extensions.")
        }
        for case let url as URL in entries {
            if (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
                entries.skipDescendants()
                continue
            }
            // Match IPAPatch's Watch exclusions, including nested Watch bundles.
            if url.deletingLastPathComponent().pathExtension == "app",
               url.lastPathComponent.hasPrefix("Watch") || url.lastPathComponent.hasPrefix("com.apple.WatchPlaceholder") {
                entries.skipDescendants()
                continue
            }
            let bundle = url.deletingLastPathComponent()
            if url.lastPathComponent == "Info.plist", bundle != root,
               ["app", "appex"].contains(bundle.pathExtension) { plists.append(url) }
        }
        if let enumerationError { throw enumerationError }
        var seen = Set<URL>()
        return try plists.sorted(by: { $0.path < $1.path }).compactMap { plist in
            let data = try Data(contentsOf: plist, options: .mappedIfSafe)
            guard data.count <= 16 * 1024 * 1024,
                  let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let name = info["CFBundleExecutable"] as? String, !name.isEmpty,
                  name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
                throw Failure(detail: "Invalid CFBundleExecutable in \(plist.path).")
            }
            let executable = plist.deletingLastPathComponent().appendingPathComponent(name)
                .resolvingSymlinksInPath().standardizedFileURL
            try requireInside(executable, root: root)
            guard seen.insert(executable).inserted else { return nil }
            let from = executable.deletingLastPathComponent().pathComponents
            let to = library.pathComponents
            let common = zip(from, to).prefix(while: { $0.0 == $0.1 }).count
            let relative = Array(repeating: "..", count: from.count - common) + Array(to.dropFirst(common))
            return Target(executable: executable, loadPath: "@executable_path/" + relative.joined(separator: "/"), infoPlist: plist)
        }
    }

    static func apply(to app: URL,
                      library: URL? = Bundle.main.url(forResource: "blatantsPatch.dylib", withExtension: "bin"),
                      identityLibrary: URL? = Bundle.main.url(forResource: "asignIdentity.dylib", withExtension: "bin"),
                      originalRootIdentifier: String? = nil,
                      replace: ((URL, URL) throws -> Void)? = nil) throws {
        let manager = FileManager.default
        let root = app.resolvingSymlinksInPath().standardizedFileURL
        let targets = try Self.targets(in: root)
        struct Library {
            let name: String
            let source: URL?
            let destination: URL
        }
        let libraries = [Library(name: identityLibraryName, source: identityLibrary,
                                 destination: root.appendingPathComponent(identityLibraryRelativePath)),
                         Library(name: libraryName, source: library,
                                 destination: root.appendingPathComponent(libraryRelativePath))]
        var injections: [URL: [Library]] = [:]
        for target in targets {
            for patch in libraries {
                var error = [CChar](repeating: 0, count: 512)
                let errorSize = error.count
                let result = KsignIPAFileHasPatchLibrary(target.executable.path, patch.name, &error, errorSize)
                guard result >= 0 else {
                    let relative = String(target.executable.path.dropFirst(root.path.count + 1))
                    throw Failure(detail: "\(relative): \(String(cString: error))")
                }
                if result == 0 { injections[target.executable, default: []].append(patch) }
            }
        }
        var libraryCopies: [Library] = []
        for patch in libraries {
            try requireInside(patch.destination.resolvingSymlinksInPath(), root: root)
            guard !targets.contains(where: { $0.executable == patch.destination }) else {
                throw Failure(detail: "The patch library destination overlaps an app executable.")
            }
            if manager.fileExists(atPath: patch.destination.path) ||
               (try? manager.destinationOfSymbolicLink(atPath: patch.destination.path)) != nil {
                guard (try manager.attributesOfItem(atPath: patch.destination.path)[.type]) as? FileAttributeType == .typeRegular else {
                    throw Failure(detail: "The existing \(patch.name) is not a regular file.")
                }
                // Keep third-party Blatant libraries. Refresh our own companion
                // from the current signer so future fixes reach prepatched apps.
                if patch.name == identityLibraryName, let source = patch.source,
                   !manager.contentsEqual(atPath: source.path, andPath: patch.destination.path) {
                    libraryCopies.append(patch)
                }
            } else {
                guard patch.source != nil else { throw Failure(detail: "The bundled \(patch.name) is missing.") }
                libraryCopies.append(patch)
            }
        }

        var identityPlists: [(URL, Data)] = []
        for target in targets {
            try requireInside(target.infoPlist.resolvingSymlinksInPath(), root: root)
            let data = try Data(contentsOf: target.infoPlist)
            var format = PropertyListSerialization.PropertyListFormat.binary
            guard var info = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
                throw Failure(detail: "Invalid Info.plist for identity compatibility.")
            }
            let captured = target.infoPlist.deletingLastPathComponent() == root ? originalRootIdentifier : nil
            guard let identifier = (info[originalIdentifierKey] as? String) ?? captured ?? (info["CFBundleIdentifier"] as? String),
                  !identifier.isEmpty else { throw Failure(detail: "Cannot determine the original bundle identifier.") }
            if info[originalIdentifierKey] as? String != identifier {
                info[originalIdentifierKey] = identifier
                identityPlists.append((target.infoPlist,
                    try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0)))
            }
        }
        guard !injections.isEmpty || !libraryCopies.isEmpty || !identityPlists.isEmpty else { return }
        let scratch = root.deletingLastPathComponent().appendingPathComponent(".IPAPatch_" + UUID().uuidString)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: scratch) }

        struct Replacement {
            let destination: URL
            let prepared: URL
            let original: URL?
        }
        var replacements: [Replacement] = []
        func stage(_ source: URL, destination: URL, permissions: Int? = nil,
                   transform: ((URL) throws -> Void)? = nil) throws {
            let index = replacements.count
            let prepared = scratch.appendingPathComponent("prepared-\(index)")
            try manager.copyItem(at: source, to: prepared)
            let attributes = try manager.attributesOfItem(atPath: prepared.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw Failure(detail: "Patch input is not a regular file: \(source.lastPathComponent)")
            }
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
            try manager.setAttributes([.posixPermissions: permissions ?? (mode | 0o200)], ofItemAtPath: prepared.path)
            try transform?(prepared)
            var original: URL?
            if manager.fileExists(atPath: destination.path) {
                let backup = scratch.appendingPathComponent("original-\(index)")
                try manager.copyItem(at: destination, to: backup)
                original = backup
            }
            replacements.append(.init(destination: destination, prepared: prepared, original: original))
        }
        for target in targets {
            guard let needed = injections[target.executable] else { continue }
            try stage(target.executable, destination: target.executable) { prepared in
                for patch in needed {
                    let loadPath = String(target.loadPath.dropLast(libraryName.count)) + patch.name
                    var error = [CChar](repeating: 0, count: 512)
                    let errorSize = error.count
                    let resolver = RunpathResolver(root: root, executable: target.executable, library: patch.destination)
                    let context = Unmanaged.passUnretained(resolver).toOpaque()
                    let result = withExtendedLifetime(resolver) {
                        KsignPatchIPAFileWithGrowth(prepared.path, loadPath, { runpath, context in
                            guard let runpath, let context else { return -1 }
                            return Unmanaged<RunpathResolver>.fromOpaque(context).takeUnretainedValue()
                                .resolve(String(cString: runpath))
                        }, context, &error, errorSize)
                    }
                    guard result >= 0 else {
                        let relative = String(target.executable.path.dropFirst(root.path.count + 1))
                        throw Failure(detail: "\(relative): \(String(cString: error))")
                    }
                }
            }
        }
        for patch in libraryCopies {
            if let source = patch.source { try stage(source, destination: patch.destination, permissions: 0o755) }
        }
        for (plist, data) in identityPlists {
            try stage(plist, destination: plist) { try data.write(to: $0) }
        }

        let frameworks = root.appendingPathComponent("Frameworks", isDirectory: true)
        let createFrameworks = !libraryCopies.isEmpty && !manager.fileExists(atPath: frameworks.path)
        if createFrameworks { try manager.createDirectory(at: frameworks, withIntermediateDirectories: false) }
        var committed: [Replacement] = []
        do {
            for replacement in replacements {
                try (replace ?? atomicReplace)(replacement.prepared, replacement.destination)
                committed.append(replacement)
            }
        } catch {
            let patchError = error
            var recoveryErrors: [String] = []
            for replacement in committed.reversed() {
                do {
                    if let original = replacement.original { try atomicReplace(original, replacement.destination) }
                    else { try manager.removeItem(at: replacement.destination) }
                } catch { recoveryErrors.append(error.localizedDescription) }
            }
            if createFrameworks { try? manager.removeItem(at: frameworks) }
            if !recoveryErrors.isEmpty {
                throw RecoveryFailure(detail: "Cannot restore the signing workspace after patching: " + recoveryErrors.joined(separator: "; "))
            }
            throw patchError
        }
    }

    private static func requireInside(_ url: URL, root: URL) throws {
        guard url.standardizedFileURL.path.hasPrefix(root.path + "/") else {
            throw Failure(detail: "Patch destination is outside the app: \(url.path)")
        }
    }

    private static func atomicReplace(_ source: URL, _ destination: URL) throws {
        if rename(source.path, destination.path) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSFilePathErrorKey: destination.path])
        }
    }
}

/// Workers only collect failures. A single UI completion or the completed batch
/// reads this report; successful patch attempts produce no user-facing output.
final class SigningPatchReport {
    private let lock = NSLock()
    private var failures: [String: (name: String, reason: String)] = [:]

    func record(id: String, name: String, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        failures[id] = (name, reason)
    }

    var summary: String? {
        lock.lock()
        defer { lock.unlock() }
        guard !failures.isEmpty else { return nil }
        let details = failures.sorted {
            $0.value.name == $1.value.name ? $0.key < $1.key : $0.value.name < $1.value.name
        }.map { "\($0.value.name): \($0.value.reason)" }.joined(separator: "\n")
        return "IPA patching failed (signing continued):\n" + details
    }
}

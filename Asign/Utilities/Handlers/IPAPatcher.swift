import Foundation
import CoreFoundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A patch attempt belongs to one private signing workspace. Prepare every
/// executable before publishing any changes; never sign a half-patched app.
enum IPAPatcher {
    static let libraryName = "asignpatch.dylib"
    static let libraryRelativePath = "Frameworks/" + libraryName
    static let legacyLibraryNames = ["blatantsPatch.dylib", "asignIdentity.dylib"]
    // Include old destinations in sparse-workspace mutation/hash exclusions.
    static let libraryRelativePaths = Set([libraryRelativePath] + legacyLibraryNames.map { "Frameworks/" + $0 })
    static let originalIdentifierKey = "AsignOriginalBundleIdentifier"
    static let originalCloudEntitlementKeys = "AsignOriginalCloudEntitlementKeys"
    static let originalCloudContainerIdentifiers = "AsignOriginalCloudContainerIdentifiers"
    static let originalAppGroupIdentifiers = "AsignOriginalAppGroupIdentifiers"
    static let originalKeychainAccessGroups = "AsignOriginalKeychainAccessGroups"
    static let originalSubscriptionRegistration = "AsignOriginalSubscriptionRegistration"
    static let preserveLegacyGroupDirectories = "AsignPreserveLegacyGroupDirectories"

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

    /// Signing must not enable cloud storage just because the selected profile
    /// supports it. Capture this before tweak injection can rewrite signatures,
    /// independently of whether runtime compatibility patching is requested.
    static func cloudEntitlementPolicy(in app: URL) -> [String: [String]] {
        let root = app.resolvingSymlinksInPath().standardizedFileURL
        guard let targets = try? Self.targets(in: root) else { return [:] }
        var policy: [String: [String]] = [:]
        for target in targets {
            guard let data = try? Data(contentsOf: target.infoPlist),
                  let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
            else { continue }
            let keys: [String]
            if let captured = info[originalCloudEntitlementKeys] {
                // A malformed first snapshot is inconclusive. Do not replace
                // it with capabilities from a later signing profile.
                guard let originalKeys = captured as? [String],
                      originalKeys.allSatisfy(OriginalCloudEntitlements.isCloudKey) else { continue }
                keys = originalKeys
            } else {
                guard let snapshot = try? OriginalCloudEntitlements.snapshot(target.executable),
                      let originalKeys = snapshot.keys else { continue }
                keys = originalKeys
            }
            let relative = String(target.executable.path.dropFirst(root.path.count + 1))
            policy[relative] = keys
        }
        return policy
    }

    /// Capture before tweaks can replace the original seal. Never infer new
    /// original groups from a previously patched app's current signature.
    static func compatibilitySnapshots(in app: URL) -> [String: OriginalCloudEntitlements.Snapshot] {
        let root = app.resolvingSymlinksInPath().standardizedFileURL
        guard let targets = try? Self.targets(in: root) else { return [:] }
        var snapshots: [String: OriginalCloudEntitlements.Snapshot] = [:]
        for target in targets {
            guard let data = try? Data(contentsOf: target.infoPlist),
                  let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
                  info[originalIdentifierKey] == nil, info[originalCloudEntitlementKeys] == nil else { continue }
            var error = [CChar](repeating: 0, count: 512)
            let errorSize = error.count
            guard KsignIPAFileHasPatchLibrary(target.executable.path, libraryName, &error, errorSize) == 0,
                  KsignIPAFileHasLegacyPatchLibrary(target.executable.path, &error, errorSize) == 0,
                  let snapshot = try? OriginalCloudEntitlements.snapshot(target.executable) else { continue }
            snapshots[String(target.executable.path.dropFirst(root.path.count + 1))] = snapshot
        }
        return snapshots
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
            if url.lastPathComponent == "Info.plist", bundle.path != root.path,
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

    @discardableResult
    static func apply(to app: URL,
                      library: URL? = Bundle.main.url(forResource: "asignpatch.dylib", withExtension: "bin"),
                      originalRootIdentifier: String? = nil,
                      originalSnapshots: [String: OriginalCloudEntitlements.Snapshot]? = nil,
                      didRemoveLibrary: ((String) -> Void)? = nil,
                      replace: ((URL, URL) throws -> Void)? = nil) throws -> [String: [String]] {
        let manager = FileManager.default
        let root = app.resolvingSymlinksInPath().standardizedFileURL
        let targets = try Self.targets(in: root)
        let snapshots = originalSnapshots ?? compatibilitySnapshots(in: root)
        struct Library {
            let name: String
            let source: URL?
            let destination: URL
        }
        let libraries = [Library(name: libraryName, source: library,
                                 destination: root.appendingPathComponent(libraryRelativePath))]
        var injections: [URL: [Library]] = [:]
        var previouslyPatched = Set<URL>()
        for target in targets {
            for patch in libraries {
                var error = [CChar](repeating: 0, count: 512)
                let errorSize = error.count
                let result = KsignIPAFileHasPatchLibrary(target.executable.path, patch.name, &error, errorSize)
                guard result >= 0 else {
                    let relative = String(target.executable.path.dropFirst(root.path.count + 1))
                    throw Failure(detail: "\(relative): \(String(cString: error))")
                }
                let legacy = KsignIPAFileHasLegacyPatchLibrary(target.executable.path, &error, errorSize)
                guard legacy >= 0 else { throw Failure(detail: String(cString: error)) }
                if result == 1 || legacy == 1 { previouslyPatched.insert(target.executable) }
                if result == 0 || legacy == 1 { injections[target.executable, default: []].append(patch) }
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
                // Refresh the unified patch so fixes reach prepatched apps.
                guard let source = patch.source else { throw Failure(detail: "The bundled \(patch.name) is missing.") }
                if !manager.contentsEqual(atPath: source.path, andPath: patch.destination.path) {
                    libraryCopies.append(patch)
                }
            } else {
                guard patch.source != nil else { throw Failure(detail: "The bundled \(patch.name) is missing.") }
                libraryCopies.append(patch)
            }
        }

        var obsolete: [URL] = []
        let bundles = Set([root] + targets.map { $0.executable.deletingLastPathComponent() })
        for bundle in bundles.sorted(by: { $0.path < $1.path }) {
            for name in legacyLibraryNames {
                let url = bundle.appendingPathComponent("Frameworks/" + name)
                try requireInside(url.resolvingSymlinksInPath(), root: root)
                if manager.fileExists(atPath: url.path) || (try? manager.destinationOfSymbolicLink(atPath: url.path)) != nil {
                    guard (try manager.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeRegular,
                          !targets.contains(where: { $0.executable == url }) else {
                        throw Failure(detail: "The legacy \(name) is not a removable library file.")
                    }
                    obsolete.append(url)
                }
            }
        }

        var identityPlists: [(URL, Data)] = []
        var cloudPolicy: [String: [String]] = [:]
        for target in targets {
            try requireInside(target.infoPlist.resolvingSymlinksInPath(), root: root)
            let data = try Data(contentsOf: target.infoPlist)
            var format = PropertyListSerialization.PropertyListFormat.binary
            guard var info = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
                throw Failure(detail: "Invalid Info.plist for identity compatibility.")
            }
            // URL equality also compares directory/trailing-slash spelling.
            // Identify the root plist by its normalized filesystem path so a
            // captured pre-onlyModify identity is used on Darwin as well.
            let isRootPlist = target.infoPlist.standardizedFileURL.path ==
                root.appendingPathComponent("Info.plist").standardizedFileURL.path
            let captured = isRootPlist ? originalRootIdentifier : nil
            guard let identifier = (info[originalIdentifierKey] as? String) ?? captured ?? (info["CFBundleIdentifier"] as? String),
                  !identifier.isEmpty else { throw Failure(detail: "Cannot determine the original bundle identifier.") }
            let relative = String(target.executable.path.dropFirst(root.path.count + 1))
            var metadataChanged = info[originalIdentifierKey] as? String != identifier
            if info[preserveLegacyGroupDirectories] == nil {
                // Older patch inputs used blanket group redirection. Record
                // that evidence before adding the new capability snapshots.
                info[preserveLegacyGroupDirectories] = previouslyPatched.contains(target.executable) &&
                    info[originalAppGroupIdentifiers] == nil && snapshots[relative] == nil
                metadataChanged = true
            }
            info[originalIdentifierKey] = identifier
            // Capture before injecting or re-signing, and keep the first
            // snapshot when this app is signed again with another profile.
            if info[originalCloudEntitlementKeys] == nil, let keys = snapshots[relative]?.keys {
                info[originalCloudEntitlementKeys] = keys
                metadataChanged = true
            }
            if info[originalCloudContainerIdentifiers] == nil, let containers = snapshots[relative]?.containers {
                info[originalCloudContainerIdentifiers] = containers
                metadataChanged = true
            }
            if info[originalAppGroupIdentifiers] == nil, let groups = snapshots[relative]?.appGroups {
                info[originalAppGroupIdentifiers] = groups
                metadataChanged = true
            }
            if info[originalKeychainAccessGroups] == nil, let groups = snapshots[relative]?.keychainGroups {
                info[originalKeychainAccessGroups] = groups
                metadataChanged = true
            }
            if info[originalSubscriptionRegistration] == nil,
               let permitted = snapshots[relative]?.subscriptionRegistration {
                info[originalSubscriptionRegistration] = permitted
                metadataChanged = true
            }
            if let keys = info[originalCloudEntitlementKeys] as? [String],
               keys.allSatisfy(OriginalCloudEntitlements.isCloudKey) {
                let relative = String(target.executable.path.dropFirst(root.path.count + 1))
                cloudPolicy[relative] = keys
            }
            if metadataChanged {
                identityPlists.append((target.infoPlist,
                    try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0)))
            }
        }
        guard !injections.isEmpty || !libraryCopies.isEmpty || !identityPlists.isEmpty || !obsolete.isEmpty else { return cloudPolicy }
        let scratch = root.deletingLastPathComponent().appendingPathComponent(".IPAPatch_" + UUID().uuidString)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: scratch) }

        struct Replacement {
            let destination: URL
            let prepared: URL?
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

        for url in obsolete {
            let backup = scratch.appendingPathComponent("original-\(replacements.count)")
            try manager.copyItem(at: url, to: backup)
            replacements.append(.init(destination: url, prepared: nil, original: backup))
        }

        let frameworks = root.appendingPathComponent("Frameworks", isDirectory: true)
        let createFrameworks = !libraryCopies.isEmpty && !manager.fileExists(atPath: frameworks.path)
        if createFrameworks { try manager.createDirectory(at: frameworks, withIntermediateDirectories: false) }
        var committed: [Replacement] = []
        do {
            for replacement in replacements {
                if let prepared = replacement.prepared {
                    try (replace ?? atomicReplace)(prepared, replacement.destination)
                } else {
                    try manager.removeItem(at: replacement.destination)
                }
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
        for url in obsolete { didRemoveLibrary?(String(url.path.dropFirst(root.path.count + 1))) }
        return cloudPolicy
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

/// Read original capability names from the executable, never from the new
/// signing profile. Unknown/DER-only signatures are inconclusive; an empty
/// result means a valid input with no cloud entitlements. Bound every read so
/// a large app does not need to be copied into memory just to inspect its seal.
enum OriginalCloudEntitlements {
    static func isCloudKey(_ key: String) -> Bool {
        key.hasPrefix("com.apple.developer.icloud-") || key.hasPrefix("com.apple.developer.ubiquity-")
    }

    struct Snapshot: Equatable {
        let keys: [String]?
        let containers: [String]?
        // nil is unknown/malformed; [] is a known empty capability list.
        var appGroups: [String]? = []
        var keychainGroups: [String]? = []
        // Only a real plist Boolean establishes the original permission.
        var subscriptionRegistration: Bool? = nil
    }

    static func read(_ url: URL) throws -> [String]? { try snapshot(url)?.keys }

    static func snapshot(_ url: URL) throws -> Snapshot? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        func bytes(_ offset: UInt64, _ count: Int) throws -> Data? {
            guard count >= 0, offset <= length, UInt64(count) <= length - offset else { return nil }
            try file.seek(toOffset: offset)
            guard let data = try file.read(upToCount: count), data.count == count else { return nil }
            return data
        }
        guard let first = try bytes(0, 8) else { return nil }
        let magic = first.cloudU32(0, big: true)
        var slices: [(UInt64, UInt64)] = [(0, length)]
        if [UInt32(0xcafebabe), 0xcafebabf, 0xbebafeca, 0xbfbafeca].contains(magic) {
            let big = magic == 0xcafebabe || magic == 0xcafebabf
            let wide = magic == 0xcafebabf || magic == 0xbfbafeca
            let count = Int(first.cloudU32(4, big: big))
            let stride = wide ? 32 : 20
            guard count > 0, count <= 64, let table = try bytes(8, count * stride) else { return nil }
            slices = []
            for index in 0..<count {
                let cursor = index * stride
                let offset = wide ? table.cloudU64(cursor + 8, big: big) : UInt64(table.cloudU32(cursor + 8, big: big))
                let size = wide ? table.cloudU64(cursor + 16, big: big) : UInt64(table.cloudU32(cursor + 12, big: big))
                guard offset >= UInt64(8 + count * stride), offset <= length, size <= length - offset else { return nil }
                slices.append((offset, size))
            }
        }
        var snapshots: [Snapshot] = []
        for (base, size) in slices {
            guard size >= 28, let prefix = try bytes(base, 28) else { return nil }
            let magic = prefix.cloudU32(0, big: true)
            guard [UInt32(0xfeedface), 0xfeedfacf, 0xcefaedfe, 0xcffaedfe].contains(magic) else { return nil }
            let big = magic == 0xfeedface || magic == 0xfeedfacf
            let headerSize = magic == 0xfeedfacf || magic == 0xcffaedfe ? 32 : 28
            let count = Int(prefix.cloudU32(16, big: big))
            let commandBytes = Int(prefix.cloudU32(20, big: big))
            guard count <= 65_536, commandBytes <= 4 * 1024 * 1024,
                  UInt64(headerSize + commandBytes) <= size,
                  let commands = try bytes(base + UInt64(headerSize), commandBytes) else { return nil }
            var cursor = 0
            var signature: Data?
            for _ in 0..<count {
                guard cursor <= commands.count - 8 else { return nil }
                let command = commands.cloudU32(cursor, big: big)
                let commandSize = Int(commands.cloudU32(cursor + 4, big: big))
                guard commandSize >= 8, commandSize <= commands.count - cursor else { return nil }
                if command == 0x1d {
                    guard signature == nil, commandSize >= 16 else { return nil }
                    let offset = UInt64(commands.cloudU32(cursor + 8, big: big))
                    let signatureSize = Int(commands.cloudU32(cursor + 12, big: big))
                    guard offset >= UInt64(headerSize + commandBytes), offset <= size,
                          signatureSize <= 16 * 1024 * 1024, UInt64(signatureSize) <= size - offset,
                          let data = try bytes(base + offset, signatureSize) else { return nil }
                    signature = data
                }
                cursor += commandSize
            }
            guard cursor == commandBytes else { return nil }
            if let signature {
                guard let keys = parseSignature(signature) else { return nil }
                snapshots.append(keys)
            } else {
                // A removed seal cannot establish what the original developer
                // requested. In particular, it must not authorize stripping
                // every cloud entitlement from the new signature.
                return nil
            }
        }
        guard let first = snapshots.first else { return nil }
        // Each family stands on its own evidence, in both directions. A cloud
        // disagreement must not disable otherwise valid group repairs either.
        return Snapshot(keys: snapshots.allSatisfy({ $0.keys == first.keys }) ? first.keys : nil,
                        containers: snapshots.allSatisfy({ $0.containers == first.containers }) ? first.containers : nil,
                        appGroups: snapshots.allSatisfy({ $0.appGroups == first.appGroups }) ? first.appGroups : nil,
                        keychainGroups: snapshots.allSatisfy({ $0.keychainGroups == first.keychainGroups }) ? first.keychainGroups : nil,
                        subscriptionRegistration: snapshots.allSatisfy({ $0.subscriptionRegistration == first.subscriptionRegistration })
                            ? first.subscriptionRegistration : nil)
    }

    private static func parseSignature(_ data: Data) -> Snapshot? {
        guard data.count >= 12, data.cloudU32(0, big: true) == 0xfade0cc0 else { return nil }
        let length = Int(data.cloudU32(4, big: true)), count = Int(data.cloudU32(8, big: true))
        guard length >= 12, length <= data.count, count <= (length - 12) / 8 else { return nil }
        var snapshot: Snapshot?
        var hasDER = false
        for index in 0..<count {
            let slot = data.cloudU32(12 + index * 8, big: true)
            if slot == 7 { hasDER = true }
            guard slot == 5 else { continue }
            let offset = Int(data.cloudU32(16 + index * 8, big: true))
            guard snapshot == nil, offset >= 12 + count * 8, offset <= length - 8,
                  data.cloudU32(offset, big: true) == 0xfade7171 else { return nil }
            let size = Int(data.cloudU32(offset + 4, big: true))
            guard size >= 8, size <= length - offset,
                  let plist = try? PropertyListSerialization.propertyList(
                    from: data.subdata(in: offset + 8..<offset + size), options: [], format: nil) as? [String: Any]
            else { return nil }
            let containerValue = plist["com.apple.developer.icloud-container-identifiers"]
            let serviceValue = plist["com.apple.developer.icloud-services"]
            let services = serviceValue as? [String]
            let containers = containerValue as? [String]
            let cloudCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
            let cloudContainers: [String]?
            if (serviceValue != nil && services == nil) || (containerValue != nil && containers == nil) ||
                !(containers ?? []).allSatisfy({ $0.hasPrefix("iCloud.") && $0.count > 7 &&
                    $0.rangeOfCharacter(from: cloudCharacters.inverted) == nil }) {
                cloudContainers = nil
            } else {
                var seen = Set<String>()
                cloudContainers = (services ?? []).contains("CloudKit")
                    ? (containers ?? []).filter { seen.insert($0).inserted } : []
            }
            func identifiers(_ value: Any?) -> [String]? {
                guard let value else { return [] }
                guard let values = value as? [String], values.allSatisfy({
                    !$0.isEmpty && $0 != "." && $0 != ".." &&
                    $0.rangeOfCharacter(from: CharacterSet(charactersIn: "*/\\")) == nil
                }) else { return nil }
                return Array(Set(values)).sorted()
            }
            let appGroups = identifiers(plist["com.apple.security.application-groups"])
            let keychain = identifiers(plist["keychain-access-groups"])
            let appID = plist["application-identifier"]
            let appIDs = identifiers(appID.map { [$0] })
            // A malformed family cannot erase known identifiers supplied by
            // another one. Missing identifiers are never inferred from this set.
            let knownKeychainGroups = Array(Set((appGroups ?? []) + (keychain ?? []) + (appIDs ?? []))).sorted()
            let keychainGroups: [String]? = !knownKeychainGroups.isEmpty || (appGroups != nil && keychain != nil && appIDs != nil)
                ? knownKeychainGroups : nil
            let registration: Bool?
            if let value = plist["com.apple.smoot.subscriptionservice"] {
                if let boolean = value as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID() {
                    registration = boolean.boolValue
                } else {
                    registration = nil
                }
            } else {
                registration = false
            }
            snapshot = Snapshot(keys: plist.keys.filter(isCloudKey).sorted(),
                                containers: cloudContainers,
                                appGroups: appGroups, keychainGroups: keychainGroups,
                                subscriptionRegistration: registration)
        }
        return snapshot ?? (hasDER ? nil : Snapshot(keys: [], containers: [], subscriptionRegistration: false))
    }
}

private extension Data {
    func cloudU32(_ offset: Int, big: Bool) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[offset + $1]) << ((big ? 3 - $1 : $1) * 8) }
    }
    func cloudU64(_ offset: Int, big: Bool) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[offset + $1]) << ((big ? 7 - $1 : $1) * 8) }
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

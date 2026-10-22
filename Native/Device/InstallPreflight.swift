import Foundation

/// A local decision, rather than an error returned by the device installer.
public struct IDeviceInstallSkip: LocalizedError {
    public let reason: String
    public var errorDescription: String? { reason }
    public init(reason: String) { self.reason = reason }
}

public struct IDeviceInstalledApplication: Decodable {
    public let bundleIdentifier: String
    public let applicationIdentifier: String?
}

/// Runs on the attempt's native worker, before opening AFC or uploading bytes.
/// Reading the incoming executable is deferred until a matching app exists.
public struct IDeviceInstallPreflight {
    public let bundleIdentifier: String
    let validateInstalledApplication: (IDeviceInstalledApplication) throws -> Void

    public init(bundleIdentifier: String,
                validateInstalledApplication: @escaping (IDeviceInstalledApplication) throws -> Void) {
        self.bundleIdentifier = bundleIdentifier
        self.validateInstalledApplication = validateInstalledApplication
    }

    public static func checkPlatform(_ info: [String: Any]) throws {
        // iPad-only declarations are deliberately eligible, including on iPhone.
        // Only reject explicit, known incompatible platforms; missing, conflicting
        // or unfamiliar declarations cannot establish an incompatibility.
        let eligible: Set<String> = ["iphoneos", "ipados", "ios"]
        let incompatible = [
            "appletvos": "tvOS", "tvos": "tvOS", "watchos": "watchOS",
            "xros": "visionOS", "visionos": "visionOS", "macosx": "macOS",
            "macos": "macOS", "maccatalyst": "Mac Catalyst",
            "iphonesimulator": "the iOS Simulator", "appletvsimulator": "the tvOS Simulator",
            "watchsimulator": "the watchOS Simulator", "xrsimulator": "the visionOS Simulator"
        ]
        let platforms = (info["CFBundleSupportedPlatforms"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty } ?? []
        let declarations: [String]
        if !platforms.isEmpty {
            declarations = platforms
        } else if let platform = info["DTPlatformName"] as? String, !platform.isEmpty {
            declarations = [platform.lowercased()]
        } else {
            // Family 1 = iPhone, 2 = iPad. Neither is a reason to skip.
            let families = info["UIDeviceFamily"] as? [Int] ?? []
            let knownFamilies = [3: "tvOS", 4: "watchOS", 6: "macOS", 7: "visionOS"]
            guard !families.isEmpty, families.allSatisfy({ knownFamilies[$0] != nil }) else { return }
            let names = Set(families.compactMap { knownFamilies[$0] }).sorted().joined(separator: ", ")
            throw IDeviceInstallSkip(reason: "This app targets \(names), not iOS or iPadOS.")
        }
        guard !declarations.contains(where: eligible.contains),
              declarations.allSatisfy({ incompatible[$0] != nil }) else { return }
        let names = Set(declarations.compactMap { incompatible[$0] }).sorted().joined(separator: ", ")
        throw IDeviceInstallSkip(reason: "This app targets \(names), not iOS or iPadOS.")
    }

    public static func signingApplicationIdentifier(executableURL: URL) throws -> String? {
        try MachOSigningIdentity.read(executableURL)?.applicationIdentifier
    }

    public static func checkSigningIdentity(executableURL: URL,
                                            installed: IDeviceInstalledApplication) throws {
        guard let existing = installed.applicationIdentifier, !existing.isEmpty,
              let incoming = try? MachOSigningIdentity.read(executableURL),
              let identifier = incoming.applicationIdentifier, !identifier.isEmpty,
              identifier != existing, !incoming.previousIdentifiers.contains(existing) else { return }
        throw IDeviceInstallSkip(reason: "An app with this bundle identifier is already installed with a different signing identity, such as an App Store copy.")
    }
}

// Read the actual signed entitlements, rather than guessing from the selected
// certificate or embedded profile. FileHandle keeps large executables off the heap.
// Unknown/malformed signatures are inconclusive and must not reject an app.
enum MachOSigningIdentity {
    struct Identity: Equatable {
        let applicationIdentifier: String?
        let previousIdentifiers: Set<String>
    }

    static func read(_ url: URL) throws -> Identity? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        func bytes(_ offset: UInt64, _ count: Int) throws -> Data? {
            guard count >= 0, offset <= length, UInt64(count) <= length - offset else { return nil }
            try file.seek(toOffset: offset)
            guard let data = try file.read(upToCount: count), data.count == count else { return nil }
            return data
        }
        guard let header = try bytes(0, 8) else { return nil }
        let magic = header.u32(0, bigEndian: true)
        var slices: [(UInt64, UInt64)] = [(0, length)]
        if [UInt32(0xcafebabe), 0xcafebabf, 0xbebafeca, 0xbfbafeca].contains(magic) {
            let big = magic == 0xcafebabe || magic == 0xcafebabf
            let wide = magic == 0xcafebabf || magic == 0xbfbafeca
            let count = Int(header.u32(4, bigEndian: big))
            guard count > 0, count <= 64, let table = try bytes(8, count * (wide ? 32 : 20)) else { return nil }
            slices = []
            for index in 0..<count {
                let base = index * (wide ? 32 : 20)
                let offset = wide ? table.u64(base + 8, bigEndian: big) : UInt64(table.u32(base + 8, bigEndian: big))
                let size = wide ? table.u64(base + 16, bigEndian: big) : UInt64(table.u32(base + 12, bigEndian: big))
                guard offset <= length, size <= length - offset else { return nil }
                slices.append((offset, size))
            }
        }
        var identities: [Identity] = []
        for (base, size) in slices {
            guard size >= 32, let header = try bytes(base, 32) else { return nil }
            let magic = header.u32(0, bigEndian: true)
            guard [UInt32(0xfeedface), 0xfeedfacf, 0xcefaedfe, 0xcffaedfe].contains(magic) else { return nil }
            let big = magic == 0xfeedface || magic == 0xfeedfacf
            let headerSize = magic == 0xfeedfacf || magic == 0xcffaedfe ? 32 : 28
            let count = Int(header.u32(16, bigEndian: big))
            let commandBytes = Int(header.u32(20, bigEndian: big))
            guard count <= 65_536, commandBytes <= 4 * 1024 * 1024,
                  UInt64(headerSize + commandBytes) <= size,
                  let commands = try bytes(base + UInt64(headerSize), commandBytes) else { return nil }
            var cursor = 0
            var identity: Identity?
            for _ in 0..<count {
                guard cursor <= commands.count - 8 else { return nil }
                let command = commands.u32(cursor, bigEndian: big)
                let commandSize = Int(commands.u32(cursor + 4, bigEndian: big))
                guard commandSize >= 8, commandSize <= commands.count - cursor else { return nil }
                if command == 0x1d { // LC_CODE_SIGNATURE
                    guard commandSize >= 16 else { return nil }
                    let offset = UInt64(commands.u32(cursor + 8, bigEndian: big))
                    let signatureSize = Int(commands.u32(cursor + 12, bigEndian: big))
                    guard signatureSize <= 16 * 1024 * 1024, offset <= size,
                          UInt64(signatureSize) <= size - offset,
                          let signature = try bytes(base + offset, signatureSize) else { return nil }
                    identity = parseSignature(signature)
                }
                cursor += commandSize
            }
            guard let identity else { return nil }
            identities.append(identity)
        }
        guard let first = identities.first, identities.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private static func parseSignature(_ data: Data) -> Identity? {
        guard data.count >= 12, data.u32(0, bigEndian: true) == 0xfade0cc0 else { return nil }
        let length = Int(data.u32(4, bigEndian: true))
        let count = Int(data.u32(8, bigEndian: true))
        guard length <= data.count, length >= 12, count <= (length - 12) / 8 else { return nil }
        for index in 0..<count {
            guard data.u32(12 + index * 8, bigEndian: true) == 5 else { continue } // CSSLOT_ENTITLEMENTS
            let offset = Int(data.u32(16 + index * 8, bigEndian: true))
            guard offset <= length - 8, data.u32(offset, bigEndian: true) == 0xfade7171 else { return nil }
            let size = Int(data.u32(offset + 4, bigEndian: true))
            guard size >= 8, size <= length - offset,
                  let plist = try? PropertyListSerialization.propertyList(
                    from: data.subdata(in: offset + 8..<offset + size), options: [], format: nil) as? [String: Any]
            else { return nil }
            return Identity(applicationIdentifier: plist["application-identifier"] as? String,
                            previousIdentifiers: Set(plist["previous-application-identifiers"] as? [String] ?? []))
        }
        return nil
    }
}

private extension Data {
    func u32(_ offset: Int, bigEndian: Bool) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { value, index in
            value | UInt32(self[offset + index]) << ((bigEndian ? 3 - index : index) * 8)
        }
    }
    func u64(_ offset: Int, bigEndian: Bool) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { value, index in
            value | UInt64(self[offset + index]) << ((bigEndian ? 7 - index : index) * 8)
        }
    }
}

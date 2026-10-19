import Foundation

// Archive IO is doubled here; policy and Mach-O inspection are production code.
enum ArchiveBackedAppError: Error { case invalidInfoPlist, rootAppNotFound }
final class ArchiveBackedApp {
    static var info: [String: Any] = [:]
    static var binary = Data()
    static var extractions = 0
    static var archives: [String: ([String: Any], Data)] = [:]
    let archiveURL: URL
    init(archiveURL: URL) throws { self.archiveURL = archiveURL }
    func data(relativePath: String, maximumBytes: Int) throws -> Data? {
        precondition(relativePath == "Info.plist")
        return try PropertyListSerialization.data(fromPropertyList: Self.archives[archiveURL.path]?.0 ?? Self.info, format: .binary, options: 0)
    }
    func extract(relativePath: String, to url: URL) throws -> Bool {
        precondition(relativePath == "App")
        Self.extractions += 1
        try (Self.archives[archiveURL.path]?.1 ?? Self.binary).write(to: url)
        return true
    }
}

@main struct InstallPreflightTests {
    static func word(_ value: UInt32, big: Bool = false) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ((big ? 3 - $0 : $0) * 8)) })
    }
    static func signedBinary(_ identifier: String, previous: [String] = []) throws -> Data {
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "application-identifier": identifier, "previous-application-identifiers": previous
        ], format: .xml, options: 0)
        let entitlement = word(0xfade7171, big: true) + word(UInt32(plist.count + 8), big: true) + plist
        let signature = word(0xfade0cc0, big: true) + word(UInt32(20 + entitlement.count), big: true)
            + word(1, big: true) + word(5, big: true) + word(20, big: true) + entitlement
        var header = word(0xfeedfacf) + word(0x0100000c) + word(0) + word(2)
        header += word(1) + word(16) + word(0) + word(0)
        return header + word(0x1d) + word(16) + word(48) + word(UInt32(signature.count)) + signature
    }
    static func fat(_ slices: [Data]) -> Data {
        var result = word(0xcafebabe, big: true) + word(UInt32(slices.count), big: true)
        var offset = 8 + 20 * slices.count
        for slice in slices {
            result += word(0x0100000c, big: true) + word(0, big: true)
                + word(UInt32(offset), big: true) + word(UInt32(slice.count), big: true) + word(0, big: true)
            offset += slice.count
        }
        for slice in slices { result += slice }
        return result
    }
    static func installed(_ identifier: String?) throws -> IDeviceInstalledApplication {
        let json: [String: Any] = ["bundleIdentifier": "app.test", "applicationIdentifier": identifier as Any? ?? NSNull()]
        return try JSONDecoder().decode(IDeviceInstalledApplication.self,
            from: JSONSerialization.data(withJSONObject: json))
    }
    static func expectSkip(_ action: () throws -> Void) throws {
        do { try action(); preconditionFailure("Expected a local skip") }
        catch is IDeviceInstallSkip { }
    }

    static func main() throws {
        // iPad-only declarations remain eligible on iPhone, without a device-family filter.
        for info: [String: Any] in [
            ["CFBundleSupportedPlatforms": ["iPhoneOS"], "UIDeviceFamily": [2]],
            ["CFBundleSupportedPlatforms": ["iPadOS"], "UIDeviceFamily": [2]],
            ["DTPlatformName": "iphoneos", "UIDeviceFamily": [2]],
            ["UIDeviceFamily": [2]], ["UIDeviceFamily": [1, 2]], [:],
            ["CFBundleSupportedPlatforms": ["FutureOS"]],
            ["CFBundleSupportedPlatforms": ["iPhoneOS", "AppleTVOS"]],
            ["CFBundleSupportedPlatforms": ["AppleTVOS", "FutureOS"]],
            ["CFBundleSupportedPlatforms": ["iPhoneOS"], "DTPlatformName": "appletvos"],
            ["CFBundleSupportedPlatforms": ["iPhoneOS"], "UIDeviceFamily": [7]],
        ] { try IDeviceInstallPreflight.checkPlatform(info) }
        for platform in ["AppleTVOS", "WatchOS", "XROS", "visionOS", "MacOSX", "iPhoneSimulator"] {
            try expectSkip { try IDeviceInstallPreflight.checkPlatform(["CFBundleSupportedPlatforms": [platform]]) }
            try expectSkip { try IDeviceInstallPreflight.checkPlatform(["DTPlatformName": platform.lowercased()]) }
        }
        for family in [3, 4, 6, 7] {
            try expectSkip { try IDeviceInstallPreflight.checkPlatform(["UIDeviceFamily": [family]]) }
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("App")
        let same = try installed("TEAM.app.test"), store = try installed("STORE.app.test")
        let normal = try signedBinary("TEAM.app.test")
        try normal.write(to: binary)
        let identity = try MachOSigningIdentity.read(binary)
        precondition(identity?.applicationIdentifier == "TEAM.app.test")
        try IDeviceInstallPreflight.checkSigningIdentity(executableURL: binary, installed: same)
        try expectSkip { try IDeviceInstallPreflight.checkSigningIdentity(executableURL: binary, installed: store) }
        try IDeviceInstallPreflight.checkSigningIdentity(executableURL: binary, installed: installed(nil))
        try signedBinary("TEAM.app.test", previous: ["STORE.app.test"]).write(to: binary)
        try IDeviceInstallPreflight.checkSigningIdentity(executableURL: binary, installed: store)
        try fat([normal, normal]).write(to: binary)
        try expectSkip { try IDeviceInstallPreflight.checkSigningIdentity(executableURL: binary, installed: store) }
        try fat([normal, signedBinary("OTHER.app.test")]).write(to: binary)
        try IDeviceInstallPreflight.checkSigningIdentity(executableURL: binary, installed: store)
        // Malformed/unknown signatures are inconclusive, never a fabricated conflict.
        for damaged in [Data(), Data(normal.prefix(47)), Data(repeating: 255, count: 64),
                        word(0xcafebabe, big: true) + word(UInt32.max, big: true)] {
            try damaged.write(to: binary)
            try IDeviceInstallPreflight.checkSigningIdentity(executableURL: binary, installed: store)
        }

        ArchiveBackedApp.info = ["CFBundleIdentifier": "app.test", "CFBundleExecutable": "App",
                                "CFBundleSupportedPlatforms": ["XROS"]]
        try expectSkip { _ = try DeviceInstallPreflight.inspect(binary) }
        precondition(ArchiveBackedApp.extractions == 0, "Wrong platforms need no executable extraction")
        ArchiveBackedApp.info["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
        ArchiveBackedApp.info["UIDeviceFamily"] = [2]
        ArchiveBackedApp.binary = normal
        let check = try DeviceInstallPreflight.inspect(binary)!
        precondition(check.bundleIdentifier == "app.test" && ArchiveBackedApp.extractions == 0)
        try check.validateInstalledApplication(installed(nil))
        precondition(ArchiveBackedApp.extractions == 0, "Missing identity must not trigger expensive extraction")
        try check.validateInstalledApplication(same)
        try expectSkip { try check.validateInstalledApplication(store) }
        precondition(ArchiveBackedApp.extractions == 2)
        let candidates: [SigningPreflight.Candidate] = [
            .init(name: "Installed", bundleIdentifier: "app.test", info: ["UIDeviceFamily": [1]]),
            .init(name: "iPad", bundleIdentifier: "app.ipad", info: ["UIDeviceFamily": [2]]),
            .init(name: "TV", bundleIdentifier: "app.tv", info: ["CFBundleSupportedPlatforms": ["AppleTVOS"]]),
            .init(name: "Unknown", bundleIdentifier: "app.unknown", info: nil),
        ]
        var queried: [String] = []
        let review = SigningPreflight.evaluate(candidates) { id in queried.append(id); return id == "app.test" }
        precondition(review.eligibleIndices == [0, 1, 3], "Installed bundle IDs warn without dropping signing work")
        precondition(review.skipped.count == 1 && review.skipped[0].name == "TV")
        precondition(review.installed.count == 1 && review.installed[0].name == "Installed")
        precondition(queried == ["app.test", "app.ipad", "app.unknown"], "Wrong platforms need no installed-app lookup")
        let source = SigningPreflight.Source(name: "Renamed", recordedIdentifier: "old.record",
            customIdentifier: "app.custom", archiveURL: binary, appDirectory: nil)
        let renamed = SigningPreflight.candidate(source)
        precondition(renamed.bundleIdentifier == "app.custom", "Review must honor the signing session's final bundle ID")
        let noOverride = SigningPreflight.Source(name: "Normal", recordedIdentifier: "old.record",
            customIdentifier: "", archiveURL: binary, appDirectory: nil)
        precondition(SigningPreflight.candidate(noOverride).bundleIdentifier == "app.test",
                     "Source Info.plist takes precedence over stale library metadata")
        print("Passed preflight platform checks, iPad-only eligibility, signed identity comparison, migration, fat binaries, malformed input and deferred extraction")
    }
}

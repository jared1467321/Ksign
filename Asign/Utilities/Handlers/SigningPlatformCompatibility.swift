import Foundation
import IDeviceSwift

/// Uses exactly the existing platform rejection rule. An iOS root with a Watch
/// companion, an iPad-only app, or inconclusive metadata never activates this.
enum SigningPlatformCompatibility {
    static func rejectionReason(_ info: [String: Any]) -> String? {
        do { try IDeviceInstallPreflight.checkPlatform(info); return nil }
        catch let error as IDeviceInstallSkip { return error.reason }
        catch { return nil }
    }

    struct Target {
        let version: String
        let minimumOS: UInt32
        let sdk: UInt32
        let sdkVersion: String

        init(system: OperatingSystemVersion, minimumOverride: String) {
            let current = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
            let currentPacked = Self.packed(current)!
            let requested = Self.packed(minimumOverride)
            // This path tries to admit an otherwise-incompatible app, even if
            // it cannot launch. Do not manufacture a requirement for the host's
            // exact release/beta version. Match Asign's oldest supported iOS.
            version = requested == nil ? "16.0" : minimumOverride
            minimumOS = requested ?? 0x100000
            sdk = max(currentPacked, minimumOS)
            sdkVersion = sdk == currentPacked ? current : minimumOverride
        }

        func exceedsMinimum(_ version: Any?) -> Bool {
            guard let version = version as? String, let packed = Self.packed(version) else { return false }
            return packed > minimumOS
        }

        private static func packed(_ version: String) -> UInt32? {
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count) else { return nil }
            let values = parts.compactMap { UInt32($0) }
            guard values.count == parts.count, values[0] > 0, values[0] <= 65535,
                  values.dropFirst().allSatisfy({ $0 <= 255 }) else { return nil }
            return values[0] << 16 | (values.count > 1 ? values[1] << 8 : 0) |
                (values.count > 2 ? values[2] : 0)
        }
    }

    /// Versioned frameworks keep Info.plist under Versions/A/Resources. Their
    /// executable is resolved from the enclosing framework, not Resources.
    static func codeBundle(containing plist: URL, inside app: URL) -> URL? {
        let root = app.standardizedFileURL
        var directory = plist.deletingLastPathComponent().standardizedFileURL
        while directory == root || directory.path.hasPrefix(root.path + "/") {
            if ["app", "appex", "framework", "bundle", "xpc", "plugin"].contains(directory.pathExtension.lowercased()) {
                let relative = String(plist.standardizedFileURL.path.dropFirst(directory.path.count + 1))
                let components = relative.split(separator: "/")
                let versioned = directory.pathExtension.lowercased() == "framework" &&
                    components.first == "Versions" &&
                    ((components.count == 4 && components[2] == "Resources" && components[3] == "Info.plist") ||
                     (components.count == 3 && components[2] == "Info.plist"))
                if ["Info.plist", "Contents/Info.plist", "Resources/Info.plist"].contains(relative) || versioned {
                    return directory
                }
                // An arbitrary data Info.plist under a bundle isn't its metadata.
                return nil
            }
            if directory == root { return nil }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    static func shouldNormalize(_ info: [String: Any], target: Target,
                                isRoot: Bool, executableWasPatched: Bool) -> Bool {
        // Some retained bundles/placeholders declare install compatibility
        // without an executable. Those declarations still belong to the app.
        isRoot || executableWasPatched || rejectionReason(info) != nil ||
            target.exceedsMinimum(info["MinimumOSVersion"])
    }

    static func normalize(_ info: inout [String: Any], target: Target, isApplication: Bool) {
        info["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
        info["DTPlatformName"] = "iphoneos"
        info["DTSDKName"] = "iphoneos" + target.sdkVersion
        // Foreign build identifiers aren't valid iOS SDK identifiers.
        info.removeValue(forKey: "DTPlatformBuild")
        info.removeValue(forKey: "DTSDKBuild")
        info.removeValue(forKey: "DTPlatformVersion")
        info["MinimumOSVersion"] = target.version
        info.removeValue(forKey: "LSMinimumSystemVersion")
        info.removeValue(forKey: "UISupportedDevices")
        info.removeValue(forKey: "UIRequiredDeviceCapabilities")
        if isApplication || info["UIDeviceFamily"] != nil {
            info["UIDeviceFamily"] = [1, 2]
        }
    }

    enum Failure: LocalizedError {
        case patch(String)
        var errorDescription: String? {
            switch self {
            case .patch(let detail): return "The iOS compatibility attempt failed: \(detail)"
            }
        }
    }
}

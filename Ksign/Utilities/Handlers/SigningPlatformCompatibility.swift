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
            version = requested == nil ? current : minimumOverride
            minimumOS = requested ?? currentPacked
            sdk = max(currentPacked, minimumOS)
            sdkVersion = sdk == currentPacked ? current : minimumOverride
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

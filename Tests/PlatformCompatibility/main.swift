import Foundation
import IDeviceSwift

// SigningPreflight's archive adapter isn't exercised by this standalone test.
final class ArchiveBackedApp {
    init(archiveURL: URL) throws {}
    func data(relativePath: String, maximumBytes: Int) throws -> Data? { nil }
}

let eligible: [[String: Any]] = [
    [:],
    ["CFBundleSupportedPlatforms": ["iPhoneOS"], "UIDeviceFamily": [1, 2]],
    ["CFBundleSupportedPlatforms": ["iPhoneOS"], "UIDeviceFamily": [2]],
    ["UIDeviceFamily": [2]],
    ["CFBundleSupportedPlatforms": ["iPhoneOS", "AppleTVOS"]],
    ["CFBundleSupportedPlatforms": ["FutureOS"]],
    ["CFBundleSupportedPlatforms": ["AppleTVOS", "FutureOS"]],
    ["DTPlatformName": "iphoneos"],
    ["UIDeviceFamily": [1, 4]],
    // A companion's declarations never activate the root's shim.
    ["CFBundleSupportedPlatforms": ["iPhoneOS"], "Watch": ["DTPlatformName": "watchos"]]
]
for info in eligible {
    precondition(SigningPlatformCompatibility.rejectionReason(info) == nil, "Eligible app activated the shim: \(info)")
}

let foreign: [[String: Any]] = [
    ["CFBundleSupportedPlatforms": ["AppleTVOS"]],
    ["CFBundleSupportedPlatforms": [" XROS "]],
    ["DTPlatformName": "visionos"],
    ["CFBundleSupportedPlatforms": ["WatchOS"]],
    ["CFBundleSupportedPlatforms": ["MacOSX"]],
    ["CFBundleSupportedPlatforms": ["iPhoneSimulator"]],
    ["UIDeviceFamily": [3]], ["UIDeviceFamily": [7]], ["UIDeviceFamily": [4, 7]]
]
let target = SigningPlatformCompatibility.Target(
    system: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 2), minimumOverride: "Default")
precondition(target.version == "26.1.2" && target.minimumOS == 0x1A0102 && target.sdk == 0x1A0102)
for original in foreign {
    precondition(SigningPlatformCompatibility.rejectionReason(original) != nil, "Foreign app missed the shim")
    var info = original
    info["CFBundleIdentifier"] = "test.preserved"
    info["CFBundleExecutable"] = "OriginalExecutable"
    info["CFBundlePackageType"] = "APPL"
    info["UIDeviceFamily"] = [7]
    info["MinimumOSVersion"] = "99.0"
    info["UIRequiredDeviceCapabilities"] = ["arkit": true]
    info["UISupportedDevices"] = ["VisionPro"]
    info["DTSDKBuild"] = "foreign-build"
    info["DTPlatformBuild"] = "foreign-build"
    info["LSMinimumSystemVersion"] = "15.0"
    SigningPlatformCompatibility.normalize(&info, target: target, isApplication: true)
    precondition(SigningPlatformCompatibility.rejectionReason(info) == nil)
    precondition(info["CFBundleSupportedPlatforms"] as? [String] == ["iPhoneOS"])
    precondition(info["UIDeviceFamily"] as? [Int] == [1, 2])
    precondition(info["DTPlatformName"] as? String == "iphoneos")
    precondition(info["MinimumOSVersion"] as? String == "26.1.2")
    precondition(info["CFBundleIdentifier"] as? String == "test.preserved")
    precondition(info["CFBundleExecutable"] as? String == "OriginalExecutable")
    precondition(info["CFBundlePackageType"] as? String == "APPL")
    for key in ["UIRequiredDeviceCapabilities", "UISupportedDevices", "DTSDKBuild", "DTPlatformBuild", "LSMinimumSystemVersion"] {
        precondition(info[key] == nil)
    }
}

let overriddenTarget = SigningPlatformCompatibility.Target(
    system: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0), minimumOverride: "16.2")
precondition(overriddenTarget.version == "16.2" && overriddenTarget.minimumOS == 0x100200 && overriddenTarget.sdk == 0x1A0000)
precondition(overriddenTarget.sdkVersion == "26.0.0")
for invalid in ["Default", "", "1..2", "1.256", "0", "65536.0", "16.1.2.3", "-1"] {
    let fallback = SigningPlatformCompatibility.Target(
        system: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0), minimumOverride: invalid)
    precondition(fallback.minimumOS == 0x1A0000)
}

// Bulk/single signing admission must pass foreign apps on to the shim while
// preserving installed-ID warnings and their de-duplication.
let candidates = (eligible + foreign).enumerated().map { index, info in
    SigningPreflight.Candidate(name: "App \(index)", bundleIdentifier: "test.same", info: info)
}
let report = SigningPreflight.evaluate(candidates, isInstalled: { $0 == "test.same" })
precondition(report.eligibleIndices == Array(candidates.indices))
precondition(report.skipped.isEmpty && report.installed.count == 1)
print("Platform trigger, plist normalization, version and signing admission tests passed.")

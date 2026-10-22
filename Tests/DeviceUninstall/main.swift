import Foundation

func require(_ value: Bool, _ message: String) {
    precondition(value, message)
}

func rejects(_ message: String, _ operation: () throws -> Void) {
    do {
        try operation()
        fatalError("Expected rejection: \(message)")
    } catch is IDeviceInstallSkip {
        // The policy must reject before sending a native removal command.
    } catch {
        fatalError("Unexpected error for \(message): \(error)")
    }
}

let bundle = "test.example.app"
let identity = "TEAM123456." + bundle
let request = try IDeviceUninstallRequest(bundleIdentifier: bundle, applicationIdentifier: identity)
let installed = IDeviceInstalledApplication(bundleIdentifier: bundle, applicationIdentifier: identity)
try require(request.validate(installed, hostBundleIdentifier: "test.ksign"), "Matching signed copy must be eligible")
try require(!request.validate(nil, hostBundleIdentifier: "test.ksign"), "Already absent must not send removal")

rejects("self removal") {
    _ = try request.validate(installed, hostBundleIdentifier: bundle)
}
rejects("self removal even when lookup is absent") {
    _ = try request.validate(nil, hostBundleIdentifier: bundle)
}
rejects("different signing team or App Store copy") {
    _ = try request.validate(.init(bundleIdentifier: bundle, applicationIdentifier: "OTHERTEAM." + bundle),
                             hostBundleIdentifier: "test.ksign")
}
rejects("unknown installed identity") {
    _ = try request.validate(.init(bundleIdentifier: bundle, applicationIdentifier: nil),
                             hostBundleIdentifier: "test.ksign")
}
rejects("unexpected lookup bundle") {
    _ = try request.validate(.init(bundleIdentifier: "test.other.app", applicationIdentifier: identity),
                             hostBundleIdentifier: "test.ksign")
}
for (bundleID, appID) in [("", "TEAM."), (bundle, ""), (bundle, "TEAM.test.different"),
                          (bundle, "." + bundle), (" " + bundle, "TEAM. " + bundle),
                          (bundle + "\0ignored", "TEAM." + bundle + "\0ignored")] {
    rejects("invalid target \(bundleID.debugDescription)") {
        _ = try IDeviceUninstallRequest(bundleIdentifier: bundleID, applicationIdentifier: appID)
    }
}

// Build a minimal signed Mach-O fixture to exercise the production identity
// reader as well as the public request initializer used by real IPA inspection.
func words(_ values: [UInt32], big: Bool) -> Data {
    var data = Data()
    for value in values {
        var encoded = big ? value.bigEndian : value.littleEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
    return data
}

func executable(_ entitlements: [String: Any]) throws -> Data {
    let plist = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
    let blob = words([0xfade7171, UInt32(8 + plist.count)], big: true) + plist
    let signature = words([0xfade0cc0, UInt32(20 + blob.count), 1, 5, 20], big: true) + blob
    let header = words([0xfeedfacf, 0x0100000c, 0, 2, 1, 16, 0, 0], big: false)
    let commands = words([0x1d, 16, 48, UInt32(signature.count)], big: false)
    return header + commands + signature
}

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("UninstallTests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
let binary = scratch.appendingPathComponent("Executable")
try executable(["application-identifier": identity]).write(to: binary)
let inspected = try IDeviceUninstallRequest(bundleIdentifier: bundle, executableURL: binary)
try require(inspected.validate(installed, hostBundleIdentifier: "test.ksign"), "Real executable identity must match")

try executable(["application-identifier": "OTHERTEAM.test.other"]).write(to: binary)
rejects("binary and Info.plist disagree") {
    _ = try IDeviceUninstallRequest(bundleIdentifier: bundle, executableURL: binary)
}
try executable([:]).write(to: binary)
rejects("unsigned identity") {
    _ = try IDeviceUninstallRequest(bundleIdentifier: bundle, executableURL: binary)
}
try Data([0, 1, 2, 3]).write(to: binary)
rejects("malformed executable") {
    _ = try IDeviceUninstallRequest(bundleIdentifier: bundle, executableURL: binary)
}
print("Device uninstall policy and signed-executable checks passed")

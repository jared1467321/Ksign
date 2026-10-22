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

// The real JSON bridge's schema. No signed files or library records are created
// by these tests: device-reported apps must be sufficient for removal.
func app(bundle: String = "test.example.app", identity: String? = "TEAM123456.test.example.app",
         type: String? = "User", removable: Bool? = nil) throws -> IDeviceInstalledApp {
    let json: [String: Any] = [
        "bundleIdentifier": bundle, "name": "Example", "version": "1.2.3",
        "applicationIdentifier": identity.map { $0 as Any } ?? NSNull(),
        "applicationType": type.map { $0 as Any } ?? NSNull(),
        "isRemovable": removable.map { $0 as Any } ?? NSNull(),
    ]
    return try JSONDecoder().decode(IDeviceInstalledApp.self,
        from: JSONSerialization.data(withJSONObject: json))
}

let installed = try app()
let bundle = installed.id
let host = "test.ksign"
let request = try IDeviceUninstallRequest(installedApp: installed, hostBundleIdentifier: host)
require(installed.name == "Example" && installed.version == "1.2.3", "Decode names and versions from iOS")
try require(request.validate(installed, hostBundleIdentifier: host), "A reviewed device app needs no saved IPA")
try require(!request.validate(nil, hostBundleIdentifier: host), "Already absent must not send removal")

// App Store and sideloaded apps are both user apps. An unavailable entitlement
// must not impose the old requirement to obtain a signed executable first.
let unknownIdentity = try app(identity: nil)
let unknownRequest = try IDeviceUninstallRequest(installedApp: unknownIdentity, hostBundleIdentifier: host)
try require(unknownRequest.validate(unknownIdentity, hostBundleIdentifier: host), "Device apps without entitlements remain removable")
let storeApp = try app(identity: "APPSTORE.test.example.app")
let storeRequest = try IDeviceUninstallRequest(installedApp: storeApp, hostBundleIdentifier: host)
try require(storeRequest.validate(storeApp, hostBundleIdentifier: host), "App Store user apps are eligible too")

rejects("self removal during selection") {
    _ = try IDeviceUninstallRequest(installedApp: installed, hostBundleIdentifier: bundle)
}
rejects("self removal before sending") {
    _ = try request.validate(installed, hostBundleIdentifier: bundle)
}
rejects("self removal even when lookup is absent") {
    _ = try request.validate(nil, hostBundleIdentifier: bundle)
}
for blocked in [try app(type: "System"), try app(type: nil), try app(removable: false)] {
    rejects("blocked app during selection") {
        _ = try IDeviceUninstallRequest(installedApp: blocked, hostBundleIdentifier: host)
    }
    rejects("app became blocked after selection") {
        _ = try request.validate(blocked, hostBundleIdentifier: host)
    }
}
for changed in [try app(identity: "OTHERTEAM.test.example.app"), try app(identity: nil),
                try app(bundle: "test.other.app")] {
    rejects("app changed after selection") {
        _ = try request.validate(changed, hostBundleIdentifier: host)
    }
}
try require(unknownRequest.validate(installed, hostBundleIdentifier: host), "A query returning additional identity metadata must not require a saved IPA")
for invalidID in ["", " " + bundle, bundle + "\n", "test. example.app", bundle + "\0ignored"] {
    rejects("invalid bundle identifier") {
        _ = try IDeviceUninstallRequest(installedApp: app(bundle: invalidID), hostBundleIdentifier: host)
    }
}
let missingOptionalFields = Data(#"{"bundleIdentifier":"test.minimal","name":"Minimal"}"#.utf8)
let minimal = try JSONDecoder().decode(IDeviceInstalledApp.self, from: missingOptionalFields)
require(minimal.version == nil && minimal.applicationIdentifier == nil, "Omitted optional metadata decodes")
rejects("unverified application type") {
    _ = try IDeviceUninstallRequest(installedApp: minimal, hostBundleIdentifier: host)
}
print("Device-list decoding and library-independent uninstall checks passed")

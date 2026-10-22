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
// Install dates win over alphabetical order; undated apps stay at the bottom.
var older = try app(bundle: "test.a-old")
older.registrationDate = Date(timeIntervalSince1970: 100)
var newest = try app(bundle: "test.z-new")
newest.registrationDate = Date(timeIntervalSince1970: 300)
var sameDateA = try app(bundle: "test.a-tie")
sameDateA.registrationDate = newest.registrationDate
let undated = try app(bundle: "test.a-undated")
let sorted = [undated, older, newest, sameDateA].sorted(by: IDeviceInstalledApp.newestFirst)
require(sorted.map(\.id) == [sameDateA.id, newest.id, older.id, undated.id], "Newest dates first, stable ties, unknown last")
require([minimal, undated].sorted(by: IDeviceInstalledApp.newestFirst).map(\.id) == [undated.id, minimal.id],
        "When dates are unavailable, names provide a stable fallback")

#if canImport(Combine)
@MainActor
func checkVPNReconnectPolicy() async {
    let suite = "Ksign.UninstallTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: VPNReconnectCoordinator.enabledKey)
    var opened = 0
    var shared = 0
    var notifications = 0
    var foreground = true
    var notificationID: String?
    var finishShareSheet: (@MainActor (Bool) -> Void)?
    @MainActor func makeCoordinator() -> VPNReconnectCoordinator {
        VPNReconnectCoordinator(
            defaults: defaults, isForeground: { foreground },
            openShortcut: { _ in opened += 1; return true },
            notify: { _, id in notifications += 1; notificationID = id; return true },
            removeNotification: { _ in },
            presentShareSheet: { _, completion in
                shared += 1
                finishShareSheet = completion
                return true
            }, dismissShareSheet: {})
    }
    let coordinator = makeCoordinator()

    for presentation in [VPNReconnectPresentation.automatic, .shareSheet] {
        defaults.set(presentation.rawValue, forKey: VPNReconnectCoordinator.presentationKey)
        let previousOpened = opened
        let previousShared = shared
        coordinator.beginDeviceWork(requiresUserChoice: true)
        await coordinator.deviceWorkFinished(restoreVPN: true)
        require(opened == previousOpened && shared == previousShared && notifications == 0 && coordinator.pendingShortcutName != nil,
                "Loading the list must leave the existing reminder without opening Shortcuts or a sheet")
        await coordinator.runPendingShortcut()
        if presentation == .automatic {
            require(opened == previousOpened + 1 && coordinator.pendingShortcutName == nil,
                    "Tapping Reconnect VPN runs the configured shortcut")
        } else {
            require(shared == previousShared + 1, "Tapping Reconnect VPN opens the configured share sheet")
            finishShareSheet?(false)
            require(coordinator.pendingShortcutName != nil, "Dismissing the sheet keeps the reminder available")
            await coordinator.runPendingShortcut()
            finishShareSheet?(true)
            require(coordinator.pendingShortcutName == nil, "Selecting the shortcut clears the reminder")
        }
    }

    defaults.set(VPNReconnectPresentation.automatic.rawValue, forKey: VPNReconnectCoordinator.presentationKey)
    let normalStart = opened
    coordinator.beginDeviceWork()
    await coordinator.deviceWorkFinished(restoreVPN: true)
    require(opened == normalStart + 1, "Ordinary installation/setup must retain its configured reconnect behavior")

    let overlapStart = opened
    coordinator.beginDeviceWork(requiresUserChoice: true)
    coordinator.beginDeviceWork()
    await coordinator.deviceWorkFinished(restoreVPN: true)
    require(opened == overlapStart && coordinator.pendingShortcutName != nil,
            "An overlapping workflow must not override the list's manual reconnect choice")
    coordinator.disable()
    require(coordinator.pendingShortcutName == nil, "The existing dismiss button clears the reminder")
    coordinator.beginDeviceWork()
    await coordinator.deviceWorkFinished(restoreVPN: true)
    require(opened == overlapStart + 1, "A later ordinary session must not inherit the manual-only policy")

    foreground = false
    let backgroundStart = opened
    coordinator.beginDeviceWork(requiresUserChoice: true)
    await coordinator.deviceWorkFinished(restoreVPN: true)
    require(opened == backgroundStart && notifications == 1 && coordinator.pendingShortcutName != nil,
            "Locked/background completion saves a pending reconnect and notification")
    foreground = true
    await coordinator.appBecameActive()
    require(opened == backgroundStart, "Unlocking alone must not run the shortcut")
    let restarted = makeCoordinator()
    require(restarted.pendingShortcutName != nil, "The existing reminder survives app relaunch")
    await restarted.runPendingShortcut()
    require(opened == backgroundStart + 1 && restarted.pendingShortcutName == nil,
            "The saved reconnect button works after relaunch")
    coordinator.disable()

    foreground = false
    coordinator.beginDeviceWork(requiresUserChoice: true)
    await coordinator.deviceWorkFinished(restoreVPN: true)
    foreground = true
    await coordinator.notificationTapped(id: notificationID!)
    require(opened == backgroundStart + 2 && coordinator.pendingShortcutName == nil,
            "Tapping the existing background notification runs the selected reconnect method")

    let noRestoreStart = opened
    coordinator.beginDeviceWork()
    await coordinator.deviceWorkFinished(restoreVPN: false)
    require(opened == noRestoreStart && coordinator.pendingShortcutName == nil, "No owned VPN means no reconnect handoff")
}

await checkVPNReconnectPolicy()
#endif
print("Device inventory, newest-first sorting, uninstall and VPN reconnect checks passed")

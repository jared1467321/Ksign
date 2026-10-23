import Foundation
import Dispatch

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

// The real JSON bridge's schema. No library records or saved IPAs are needed,
// but a persisted receipt for this particular installed copy is mandatory.
func app(bundle: String = "test.example.app", identity: String? = "TEAM123456.test.example.app",
         type: String? = "User", removable: Bool? = nil,
         path: String? = "/private/var/containers/Bundle/Application/ASIGN-COPY/Example.app") throws -> IDeviceInstalledApp {
    let json: [String: Any] = [
        "bundleIdentifier": bundle, "name": "Example", "version": "1.2.3",
        "applicationIdentifier": identity.map { $0 as Any } ?? NSNull(),
        "installationPath": path.map { $0 as Any } ?? NSNull(),
        "applicationType": type.map { $0 as Any } ?? NSNull(),
        "isRemovable": removable.map { $0 as Any } ?? NSNull(),
    ]
    return try JSONDecoder().decode(IDeviceInstalledApp.self,
        from: JSONSerialization.data(withJSONObject: json))
}

let installed = try app()
let bundle = installed.id
let host = "test.asign"
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Asign-OwnershipTests-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let registryURL = directory.appendingPathComponent("ManagedInstalls.json")
let registry = IDeviceManagedInstallRegistry(fileURL: registryURL)
try require(registry.snapshot().isEmpty, "A new registry grants no uninstall permission")
rejects("device app without a Asign receipt") {
    _ = try IDeviceUninstallRequest(installedApp: installed, hostBundleIdentifier: host, registry: registry)
}
try registry.recordConfirmedInstall(installed, hostBundleIdentifier: host)
let receipt = try registry.snapshot().first!
let reopened = IDeviceManagedInstallRegistry(fileURL: registryURL)
try require(reopened.snapshot() == [receipt], "Ownership survives relaunch independently of library files")
let request = try IDeviceUninstallRequest(installedApp: installed, hostBundleIdentifier: host, registry: registry)
require(installed.name == "Example" && installed.version == "1.2.3", "Decode names and versions from iOS")
try require(request.validate(installed, hostBundleIdentifier: host), "A reviewed device app needs no saved IPA")
try require(!request.validate(nil, hostBundleIdentifier: host), "Already absent must not send removal")

let unknownIdentity = try app(identity: nil)
let storeApp = try app(identity: "APPSTORE.test.example.app")
for unowned in [unknownIdentity, storeApp, try app(path: nil),
                try app(path: "/private/var/containers/Bundle/Application/REPLACEMENT/Example.app")] {
    rejects("untracked, unverifiable or replaced copy during selection") {
        _ = try IDeviceUninstallRequest(installedApp: unowned, hostBundleIdentifier: host, registry: registry)
    }
    rejects("replacement after selection") {
        _ = try request.validate(unowned, hostBundleIdentifier: host)
    }
}

rejects("self removal during selection") {
    _ = try IDeviceUninstallRequest(installedApp: installed, hostBundleIdentifier: bundle, registry: registry)
}
rejects("self removal before sending") {
    _ = try request.validate(installed, hostBundleIdentifier: bundle)
}
rejects("self removal even when lookup is absent") {
    _ = try request.validate(nil, hostBundleIdentifier: bundle)
}
for blocked in [try app(type: "System"), try app(type: nil), try app(removable: false)] {
    rejects("blocked app during selection") {
        _ = try IDeviceUninstallRequest(installedApp: blocked, hostBundleIdentifier: host, registry: registry)
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
try require(registry.snapshot() == [receipt], "Rejected or cancelled removals preserve ownership for retry")
for invalidID in ["", " " + bundle, bundle + "\n", "test. example.app", bundle + "\0ignored"] {
    rejects("invalid bundle identifier") {
        _ = try IDeviceUninstallRequest(installedApp: app(bundle: invalidID), hostBundleIdentifier: host, registry: registry)
    }
}
let missingOptionalFields = Data(#"{"bundleIdentifier":"test.minimal","name":"Minimal"}"#.utf8)
let minimal = try JSONDecoder().decode(IDeviceInstalledApp.self, from: missingOptionalFields)
require(minimal.version == nil && minimal.applicationIdentifier == nil, "Omitted optional metadata decodes")
rejects("unverified application type") {
    _ = try IDeviceUninstallRequest(installedApp: minimal, hostBundleIdentifier: host, registry: registry)
}

let unrelated = try app(bundle: "test.store", identity: "STORE.test.store")
let listed = try registry.reconcile([installed, unrelated, minimal], observed: registry.snapshot(), hostBundleIdentifier: host)
require(listed.map(\.id) == [bundle], "Only verified Asign installations appear in the list")
let unverifiableList = try registry.reconcile([unknownIdentity], observed: registry.snapshot(), hostBundleIdentifier: host)
require(unverifiableList.isEmpty, "Missing metadata hides an unverifiable copy")
try require(registry.snapshot() == [receipt], "Unavailable metadata must not destroy a valid receipt")
try request.didRemove()
try require(registry.snapshot().isEmpty, "Confirmed removal clears its persistent receipt")
try require(IDeviceManagedInstallRegistry(fileURL: registryURL).snapshot().isEmpty, "Removed receipts stay gone after relaunch")
rejects("old selection after receipt removal") {
    _ = try request.validate(installed, hostBundleIdentifier: host)
}

try registry.recordConfirmedInstall(installed, hostBundleIdentifier: host)
let absentRequest = try IDeviceUninstallRequest(installedApp: installed, hostBundleIdentifier: host, registry: registry)
try require(!absentRequest.validate(nil, hostBundleIdentifier: host), "An already absent app sends no uninstall command")
try absentRequest.didRemove()
try require(registry.snapshot().isEmpty, "Already absent also clears tracking")

// A stale completion or inventory must never delete a newer installation.
try registry.recordConfirmedInstall(installed, hostBundleIdentifier: host)
let staleRequest = try IDeviceUninstallRequest(installedApp: installed, hostBundleIdentifier: host, registry: registry)
let oldSnapshot = try registry.snapshot()
try registry.recordConfirmedInstall(installed, hostBundleIdentifier: host)
let newerReceipt = try registry.snapshot()
try staleRequest.didRemove()
try require(registry.snapshot() == newerReceipt, "Stale removal preserves a newer receipt")
_ = try registry.reconcile([], observed: oldSnapshot, hostBundleIdentifier: host)
try require(registry.snapshot() == newerReceipt, "Old inventory cannot prune a concurrent install")
_ = try registry.reconcile([], observed: registry.snapshot(), hostBundleIdentifier: host)
try require(registry.snapshot().isEmpty, "Successful refresh prunes absent apps")
try registry.recordConfirmedInstall(installed, hostBundleIdentifier: host)
_ = try registry.reconcile([storeApp], observed: registry.snapshot(), hostBundleIdentifier: host)
try require(registry.snapshot().isEmpty, "Refresh prunes replaced copies")

// Neither an unverifiable success nor a system/self app establishes ownership.
for unverifiable in [unknownIdentity, try app(path: nil), try app(type: "System"), try app(removable: false)] {
    try registry.recordConfirmedInstall(unverifiable, hostBundleIdentifier: host)
}
try registry.recordConfirmedInstall(installed, hostBundleIdentifier: bundle)
try require(registry.snapshot().isEmpty, "Unknown identities, copy bindings, system apps and Asign stay untracked")

let oldDate = Date(timeIntervalSince1970: 100)
let newDate = Date(timeIntervalSince1970: 200)
let identity = installed.applicationIdentifier!
try registry.recordObservedInstall(bundleIdentifier: bundle, applicationIdentifier: identity,
    previousRegistrationDate: oldDate, registrationDate: oldDate, preparedAt: oldDate, hostBundleIdentifier: host)
try registry.recordObservedInstall(bundleIdentifier: bundle, applicationIdentifier: identity,
    previousRegistrationDate: oldDate, registrationDate: nil, preparedAt: oldDate, hostBundleIdentifier: host)
try registry.recordObservedInstall(bundleIdentifier: bundle, applicationIdentifier: identity,
    previousRegistrationDate: nil, registrationDate: oldDate, preparedAt: newDate, hostBundleIdentifier: host)
try registry.recordObservedInstall(bundleIdentifier: bundle, applicationIdentifier: identity,
    previousRegistrationDate: newDate, registrationDate: oldDate, preparedAt: oldDate, hostBundleIdentifier: host)
try require(registry.snapshot().isEmpty, "A server prompt or unchanged registration grants no ownership")
try registry.recordObservedInstall(bundleIdentifier: bundle, applicationIdentifier: identity,
    previousRegistrationDate: oldDate, registrationDate: newDate, preparedAt: oldDate, hostBundleIdentifier: host)
var serverApp = installed
serverApp.registrationDate = newDate
let serverRequest = try IDeviceUninstallRequest(installedApp: serverApp, hostBundleIdentifier: host, registry: registry)
try require(serverRequest.validate(serverApp, hostBundleIdentifier: host), "A confirmed server copy is removable without its IPA")
for date in [Optional(oldDate), nil] {
    var changed = serverApp
    changed.registrationDate = date
    rejects("server copy changed or registration unavailable") {
        _ = try serverRequest.validate(changed, hostBundleIdentifier: host)
    }
}
try serverRequest.didRemove()

let corruptURL = directory.appendingPathComponent("corrupt.json")
try Data("broken".utf8).write(to: corruptURL)
let corrupt = IDeviceManagedInstallRegistry(fileURL: corruptURL)
rejects("corrupt ownership file must fail closed") { _ = try corrupt.snapshot() }
rejects("corrupt ownership file must not be silently overwritten") {
    try corrupt.recordConfirmedInstall(installed, hostBundleIdentifier: host)
}
require(try String(contentsOf: corruptURL, encoding: .utf8) == "broken", "Corrupt file preserved")
let obstructed = directory.appendingPathComponent("not-a-directory")
let unwritable = IDeviceManagedInstallRegistry(fileURL: obstructed.appendingPathComponent("records.json"))
try Data().write(to: obstructed)
rejects("failed persistence cannot grant ownership") {
    try unwritable.recordConfirmedInstall(installed, hostBundleIdentifier: host)
}
try require(unwritable.snapshot().isEmpty, "An unsuccessful write must not change the in-memory allowlist")

let concurrentURL = directory.appendingPathComponent("concurrent.json")
let concurrentRegistry = IDeviceManagedInstallRegistry(fileURL: concurrentURL)
DispatchQueue.concurrentPerform(iterations: 16) { index in
    do {
        let identifier = "test.concurrent.\(index)"
        try concurrentRegistry.recordConfirmedInstall(
            app(bundle: identifier, identity: "TEAM.\(identifier)"), hostBundleIdentifier: host)
    } catch { fatalError("Concurrent receipt write failed: \(error)") }
}
try require(concurrentRegistry.snapshot().count == 16, "Concurrent installs must not overwrite each other's receipts")
try require(IDeviceManagedInstallRegistry(fileURL: concurrentURL).snapshot().count == 16,
            "Every concurrent receipt survives relaunch")

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

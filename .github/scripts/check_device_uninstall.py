#!/usr/bin/env python3
"""Exercise production removal scheduling with a simulated device on Linux/macOS.

Native transport, VPN/pairing, Combine and background-task APIs are substituted.
The batch, worker, receipt validation, manager and observable model are compiled
from production sources. This does not test iOS's installer service itself.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]

STUBS = r'''
import Foundation

func require(_ value: Bool, _ message: String) {
    if !value { fatalError(message) }
}
func autoreleasepool<T>(_ body: () throws -> T) rethrows -> T { try body() }
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
protocol ObservableObject: AnyObject {}
final class AnyCancellable {}
struct NotificationPublisher {
    func sink(_ body: @escaping (Notification) -> Void) -> AnyCancellable { AnyCancellable() }
}
extension NotificationCenter {
    func publisher(for name: Notification.Name, object: Any?) -> NotificationPublisher { NotificationPublisher() }
}
public struct IDeviceInstallSkip: LocalizedError {
    public let reason: String
    public var errorDescription: String? { reason }
}
public struct IDeviceInstallationRejection: LocalizedError {
    let message: String
    public var errorDescription: String? { message }
}
struct IDeviceSwiftError: Error { let message: String }
public struct IDeviceInstallPreflight {}
final class InstallerStatusViewModel {}
enum IDeviceInstalledAppDates {
    static func registrationDate(for id: String) -> Date? { nil }
}
enum UIApplication {
    static func installedAppPresence(_ id: String) -> Bool? {
        MockDevice.shared.read { $0.localPresence[id] }
    }
}
struct DeviceSetupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
struct DevicePairingRecord {}
enum DevicePairingStore {
    static func scheduleWorkingCopyRemoval() {}
    static func load() async throws -> DevicePairingRecord? { DevicePairingRecord() }
    static func save(_ record: DevicePairingRecord) async throws {}
    static func materialize(_ record: DevicePairingRecord) async throws -> URL { URL(fileURLWithPath: "/tmp/pairing") }
    static func removeWorkingCopy() async {}
    static func reset() async throws {}
}
@MainActor final class DevicePairingService {
    static let shared = DevicePairingService()
    func pair() async throws -> DevicePairingRecord { DevicePairingRecord() }
    func cancel() {}
}
@MainActor final class LocalDeviceVPN {
    static let extensionBundleIdentifier: String? = "test.tunnel"
    func connect(restarting: Bool) async throws {}
    func disconnectIfOwned() {}
    func finishSession() async -> Bool { false }
}
@MainActor final class VPNReconnectCoordinator {
    static let shared = VPNReconnectCoordinator()
    func beginDeviceWork(requiresUserChoice: Bool = false) {}
    func deviceWorkFinished(restoreVPN: Bool) async {}
    func runConfiguredShortcut() async {}
}
@MainActor final class HeartbeatManager {
    static let shared = HeartbeatManager()
    var resets = 0
    func resetInstallationConnection() async { resets += 1 }
    func prepareInstallationConnection() async throws {}
    static func configurePairingPath(_ path: String?) {}
}
@MainActor final class InstallSession {
    static let shared = InstallSession()
    var hasWorkInProgress = false
    var waitingCount = 0
}
@MainActor final class BackgroundTaskManager {
    enum Owner { case installedApps, uninstalling }
    static let shared = BackgroundTaskManager()
    func claim(_ owner: Owner) {}
    func release(_ owner: Owner, success: Bool) {}
    func report(_ owner: Owner, completed: Int?, total: Int?, fraction: Double?, detail: String?, currentItem: String? = nil) {}
}

enum TransportFailure: Error { case disconnected }
final class Client {
    let thread = Thread.current
    let id: Int
    init(_ id: Int) { self.id = id }
}
final class MockDevice: @unchecked Sendable {
    enum Behavior { case success, reject, disconnected, stillInstalled }
    static let shared = MockDevice()
    let lock = NSLock()
    var apps: [String: IDeviceInstalledApp] = [:]
    var omittedFromInventory: Set<String> = []
    var omittedFromLookup: Set<String> = []
    var localPresence: [String: Bool] = [:]
    var commands: [(id: String, client: Int)] = []
    var gates: [String: DispatchSemaphore] = [:]
    var behavior: [String: Behavior] = [:]
    var blocked = true
    var active = 0
    var peak = 0
    var opened = 0
    var closed = 0
    var installStarted = false
    func read<T>(_ body: (MockDevice) -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body(self)
    }
    func reset(_ apps: [IDeviceInstalledApp], behavior: [String: Behavior] = [:]) {
        lock.lock(); defer { lock.unlock() }
        require(active == 0 && opened == closed, "previous batch leaked clients")
        self.apps = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        omittedFromInventory = []; omittedFromLookup = []; localPresence = [:]
        commands = []; gates = [:]; self.behavior = behavior
        blocked = true; active = 0; peak = 0; opened = 0; closed = 0; installStarted = false
    }
    func release(_ id: String) { read { $0.gates[id] }?.signal() }
    func releaseAll() {
        lock.lock(); blocked = false; let pending = Array(gates.values); lock.unlock()
        for gate in pending { gate.signal() }
    }
    func uninstall(_ id: String, client: Client) -> Error? {
        require(Thread.current === client.thread, "native client moved threads")
        lock.lock()
        commands.append((id, client.id)); active += 1; peak = max(peak, active)
        let gate = DispatchSemaphore(value: 0); gates[id] = gate
        if !blocked { gate.signal() }
        let mode = behavior[id] ?? .success
        lock.unlock()
        require(gate.wait(timeout: .now() + 10) == .success, "test did not release command")
        lock.lock(); defer { lock.unlock() }
        active -= 1
        switch mode {
        case .success: apps[id] = nil; return nil
        case .reject: return IDeviceInstallationRejection(message: "rejected")
        case .disconnected: apps[id] = nil; return TransportFailure.disconnected
        case .stillInstalled: return nil
        }
    }
}
func installation_proxy_uninstall(_ pointer: OpaquePointer?, _ id: String, _ options: OpaquePointer?) -> Error? {
    let client = Unmanaged<Client>.fromOpaque(UnsafeRawPointer(pointer!)).takeUnretainedValue()
    return MockDevice.shared.uninstall(id, client: client)
}

public final class InstallationProxy {
    private let cancellation = IDeviceInstallCancellation()
    init(viewModel: InstallerStatusViewModel = InstallerStatusViewModel()) {}
    private func checkCancellation() throws { try cancellation.check() }
    private func check(_ error: Error?) throws { if let error { throw error } }
    private func lookup(_ id: String, client pointer: OpaquePointer?) throws -> IDeviceInstalledApp? {
        let client = Unmanaged<Client>.fromOpaque(UnsafeRawPointer(pointer!)).takeUnretainedValue()
        require(Thread.current === client.thread, "lookup moved native client threads")
        return MockDevice.shared.read { $0.omittedFromLookup.contains(id) ? nil : $0.apps[id] }
    }
    private func withDeviceClient<T>(_ body: (OpaquePointer?) throws -> T) throws -> T {
        let id = MockDevice.shared.read { $0.opened += 1; return $0.opened }
        let client = Client(id)
        let pointer = Unmanaged.passRetained(client).toOpaque()
        defer {
            require(Thread.current === client.thread, "native client freed on another thread")
            Unmanaged<Client>.fromOpaque(pointer).release()
            MockDevice.shared.read { $0.closed += 1 }
        }
        try checkCancellation()
        return try body(OpaquePointer(pointer))
    }
    private func ksign_installation_list(_ client: OpaquePointer?, _ output: inout UnsafeMutablePointer<CChar>?) -> Error? {
        let apps = MockDevice.shared.read { device in
            device.apps.values.filter { !device.omittedFromInventory.contains($0.id) }
        }
        let encoded = try! JSONEncoder().encode(apps)
        output = strdup(String(decoding: encoded, as: UTF8.self))
        return nil
    }
    private func ksign_pairing_string_free(_ output: UnsafeMutablePointer<CChar>?) { free(output) }
    func validate(_ preflight: IDeviceInstallPreflight) async throws {}
    func install(at url: URL, suspend: Bool, preflight: IDeviceInstallPreflight?, isCurrent: @escaping () -> Bool) async throws {
        MockDevice.shared.read { $0.installStarted = true }
    }
'''

TESTS = r'''
func fixture(_ count: Int, registry: IDeviceManagedInstallRegistry? = nil) throws -> ([IDeviceInstalledApp], IDeviceManagedInstallRegistry) {
    let registry = registry ?? IDeviceManagedInstallRegistry(fileURL:
        URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString))
    let apps = (0..<count).map { index in
        IDeviceInstalledApp(bundleIdentifier: "test.app\(index)", name: "App \(index)", version: "1",
            applicationIdentifier: "TEAM.test.app\(index)", installationPath: "/apps/\(index)",
            applicationType: "User", isRemovable: true)
    }
    for app in apps { try registry.recordConfirmedInstall(app, hostBundleIdentifier: nil) }
    MockDevice.shared.reset(apps)
    return (apps, registry)
}
func waitUntil(_ message: String, _ body: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !(await body()) {
        require(Date() < deadline, message)
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}
func run(_ batch: IDeviceUninstallBatch, concurrency: Int = 5,
         check: @escaping @Sendable (String) throws -> Void = { _ in }) -> Task<Void, Error> {
    Task {
        try await InstallationProxy().uninstall(batch, concurrency: concurrency, checkRemovalAllowed: check,
            localPresence: { id in MockDevice.shared.read { $0.apps[id] != nil } }, onEvent: { _ in })
    }
}

@main struct Tests {
    @MainActor static func main() async throws {
        let device = MockDevice.shared
        do {
            let file = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("server-receipts.json")
            let started = Date(timeIntervalSince1970: 1_700_000_000)
            let served = started.addingTimeInterval(4)
            let query = served.addingTimeInterval(10)
            let bundle = "test.server"
            let identity = "TEAM.test.server"
            let previous = "/var/apps/old"
            let oldDate = started.addingTimeInterval(-100)
            let observation = IDeviceServerInstallObservation(bundleIdentifier: bundle,
                applicationIdentifier: identity, version: "2", startedAt: started,
                previousRegistrationDate: oldDate, previousPath: previous, wasAbsent: false)
            struct LegacyRegistry: Encodable {
                let version = 1
                let records: [IDeviceManagedInstall]
            }
            let nativeReceipt = IDeviceManagedInstall(token: UUID(), bundleIdentifier: "test.native",
                applicationIdentifier: "TEAM.test.native", installationPath: "/apps/native",
                registrationDate: nil, installedAt: oldDate)
            try JSONEncoder().encode(LegacyRegistry(records: [nativeReceipt])).write(to: file)
            let before = IDeviceManagedInstallRegistry(fileURL: file)
            try before.recordServerOffer(observation, hostBundleIdentifier: nil)

            func app(identity: String = identity, version: String = "2", path: String,
                     date: Date? = nil) -> IDeviceInstalledApp {
                var app = IDeviceInstalledApp(bundleIdentifier: bundle, name: "Server App", version: version,
                    applicationIdentifier: identity, installationPath: path, applicationType: "User", isRemovable: true)
                app.registrationDate = date
                return app
            }

            let registry = IDeviceManagedInstallRegistry(fileURL: file)
            let updated = app(path: "/private/var/apps/new")
            func load(_ app: IDeviceInstalledApp, at date: Date = query) throws -> [IDeviceInstalledApp] {
                try registry.reconcile([app], observed: registry.snapshot(), hostBundleIdentifier: nil, inventoryStartedAt: date)
            }
            require(try load(updated).map(\.id) == [nativeReceipt.bundleIdentifier], "an interrupted offer authorized uninstall")
            try registry.recordServerTransfer(observation, servedAt: served, hostBundleIdentifier: nil)
            require(try before.snapshot() == [nativeReceipt], "a transfer changed an existing native receipt")
            require(try !load(updated, at: started).contains { $0.id == bundle }, "inventory predating the transfer consumed its evidence")
            require(try !load(app(path: "/private/var/apps/old", date: oldDate)).contains { $0.id == bundle }, "an unchanged preexisting copy was adopted")
            require(try !load(app(identity: "OTHER.test.server", path: "/apps/new")).contains { $0.id == bundle }, "another signing identity was adopted")
            require(try !load(app(version: "3", path: "/apps/new")).contains { $0.id == bundle }, "a different version was adopted")
            require(observation.sawNewCopy(path: updated.installationPath, registrationDate: oldDate,
                servedAt: served, now: query), "a changed path with a stable registration date was missed")
            require(try Set(load(updated).map(\.id)) == [nativeReceipt.bundleIdentifier, bundle],
                "a new copy from the persisted transfer was hidden")
            let canonical = try load(app(path: "/var/apps/new")).first { $0.id == bundle }
            require(canonical?.trackingRestriction == nil, "a path alias invalidated a receipt")
            let omitted = try registry.reconcile([], observed: registry.snapshot(), hostBundleIdentifier: nil)
            require(omitted.contains { $0.id == bundle && $0.name == updated.name && $0.trackingRestriction != nil },
                "an incomplete inventory hid a verified server install")
            let request = try IDeviceUninstallRequest(installedApp: updated, hostBundleIdentifier: nil, registry: registry)
            require(try request.validate(updated, hostBundleIdentifier: nil), "a verified server install could not be uninstalled")
            do {
                _ = try request.validate(app(path: "/apps/replacement"), hostBundleIdentifier: nil)
                fatalError("a replacement copy was authorized for uninstall")
            } catch is IDeviceInstallSkip {}

            let fresh = IDeviceServerInstallObservation(bundleIdentifier: bundle,
                applicationIdentifier: identity, version: "2", startedAt: started,
                previousRegistrationDate: nil, previousPath: nil, wasAbsent: true)
            require(fresh.sawNewCopy(path: "/apps/new", registrationDate: nil, servedAt: served, now: query),
                "a fresh installation without a device date was missed")
            require(!fresh.sawNewCopy(path: "/apps/new", registrationDate: nil, servedAt: served,
                now: served.addingTimeInterval(3601)), "a path-only observation was accepted outside the attribution window")
            require(fresh.sawNewCopy(path: "/apps/new", registrationDate: query, servedAt: served,
                now: served.addingTimeInterval(3601)), "a dated installation could not be confirmed later")
        }
        print("PASS server transfers survive restart and authorize only matching new device copies")

        do {
            let file = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("server-batches.json")
            let started = Date(timeIntervalSince1970: 1_700_000_000)
            let nextBatch = started.addingTimeInterval(8 * 24 * 3600)
            let registry = IDeviceManagedInstallRegistry(fileURL: file)

            func transfer(_ id: String, at time: Date, previousPath: String? = nil) throws -> IDeviceServerInstallObservation {
                let observation = IDeviceServerInstallObservation(bundleIdentifier: id, applicationIdentifier: "TEAM.\(id)",
                    version: "1", startedAt: time, previousRegistrationDate: nil, previousPath: previousPath,
                    wasAbsent: previousPath == nil)
                try registry.recordServerTransfer(observation, servedAt: time.addingTimeInterval(1), hostBundleIdentifier: nil)
                return observation
            }

            func app(_ id: String, path: String? = nil) -> IDeviceInstalledApp {
                IDeviceInstalledApp(bundleIdentifier: id, name: id, version: "1", applicationIdentifier: "TEAM.\(id)",
                    installationPath: path ?? "/private/var/apps/\(id)", applicationType: "User", isRemovable: true)
            }

            let first = try transfer("first", at: started)
            let retry = try transfer("retry", at: started)
            let replaced = try transfer("replaced", at: started)
            _ = try transfer("dated", at: started)
            for observation in [first, retry, replaced] {
                try registry.recordServerRegistration(observation, path: "/var/apps/\(observation.bundleIdentifier)",
                    registrationDate: nil, observedAt: started.addingTimeInterval(2))
            }
            // Native and server batches share the same file, including across relaunches.
            let nativeFirst = app("native-first")
            let nativeSecond = app("native-second")
            try IDeviceManagedInstallRegistry(fileURL: file).recordConfirmedInstall(nativeFirst, hostBundleIdentifier: nil)
            _ = try transfer("retry", at: nextBatch, previousPath: "/var/apps/retry")
            _ = try transfer("second", at: nextBatch)
            try IDeviceManagedInstallRegistry(fileURL: file).recordConfirmedInstall(nativeSecond, hostBundleIdentifier: nil)
            let restored = IDeviceManagedInstallRegistry(fileURL: file)
            var dated = app("dated")
            dated.registrationDate = started.addingTimeInterval(4)
            let apps = [app("first"), app("retry"), app("second"), dated, nativeFirst, nativeSecond,
                app("replaced", path: "/var/apps/other-copy")]
            let visible = try restored.reconcile(apps, observed: restored.snapshot(), hostBundleIdentifier: nil,
                inventoryStartedAt: nextBatch.addingTimeInterval(5))
            require(Set(visible.map(\.id)) == ["first", "retry", "second", "dated", nativeFirst.id, nativeSecond.id],
                "alternating install methods lost earlier receipts or adopted a replacement copy")
            require(visible.allSatisfy { $0.trackingRestriction == nil }, "mixed installs could not be verified")
            require((try restored.snapshot()).count == 6, "a retried bundle produced duplicate receipts")
        }
        print("PASS alternating native and server batches preserve verified apps across restarts and retries")

        do {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("parallel", isDirectory: true)
            let file = directory.appendingPathComponent("receipts.json")
            let registry = IDeviceManagedInstallRegistry(fileURL: file)
            let apps = (0..<32).map { index in
                IDeviceInstalledApp(bundleIdentifier: "parallel.\(index)", name: "App \(index)", version: "1",
                    applicationIdentifier: "TEAM.parallel.\(index)", installationPath: "/apps/\(index)",
                    applicationType: "User", isRemovable: true)
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for app in apps {
                    group.addTask {
                        try IDeviceManagedInstallRegistry(fileURL: file).recordConfirmedInstall(app, hostBundleIdentifier: nil)
                    }
                }
                try await group.waitForAll()
            }
            let prior = try registry.snapshot()
            require(Set(prior.map(\.bundleIdentifier)) == Set(apps.map(\.id)), "concurrent writers lost a receipt")

            let old = prior.first { $0.bundleIdentifier == apps[0].id }!
            let reinstalled = IDeviceInstalledApp(bundleIdentifier: apps[0].id, name: "Reinstalled", version: "2",
                applicationIdentifier: apps[0].applicationIdentifier, installationPath: "/apps/reinstalled",
                applicationType: "User", isRemovable: true)
            try registry.recordConfirmedInstall(reinstalled, hostBundleIdentifier: nil)
            require(try !registry.remove(old), "a stale uninstall cleared a newer receipt")
            let partial = try registry.reconcile([], observed: prior, verifiedAbsent: [apps[0].id, apps[1].id],
                hostBundleIdentifier: nil)
            require(partial.count == 31 && partial.contains { $0.id == apps[0].id && $0.name == reinstalled.name }
                && partial.allSatisfy { $0.trackingRestriction != nil },
                "a stale refresh removed a reinstall, or an incomplete inventory removed another app")

            let replacement = IDeviceInstalledApp(bundleIdentifier: apps[2].id, name: "Replacement", version: "2",
                applicationIdentifier: "OTHER.parallel.2", installationPath: "/other/replacement",
                applicationType: "User", isRemovable: true)
            let view = try registry.reconcile([replacement], observed: registry.snapshot(), hostBundleIdentifier: nil)
            require(view.first { $0.id == replacement.id }?.trackingRestriction != nil,
                "a replacement disappeared or became eligible for uninstall")

            let saved = try Data(contentsOf: file)
            do {
                let files = FileManager.default
                try files.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
                defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
                if !files.isWritableFile(atPath: directory.path) {
                    do {
                        try registry.recordConfirmedInstall(apps[1], hostBundleIdentifier: nil)
                        fatalError("an unwritable directory accepted an atomic save")
                    } catch is IDeviceInstallSkip {}
                    require(try Data(contentsOf: file) == saved, "a failed save changed the previously committed registry")
                    print("PASS failed atomic save preserves the committed file")
                }
            }
            let corrupt = Data("incomplete JSON".utf8)
            try corrupt.write(to: file, options: .atomic)
            do {
                try registry.recordConfirmedInstall(apps[1], hostBundleIdentifier: nil)
                fatalError("a corrupt registry was overwritten")
            } catch is IDeviceInstallSkip {}
            require(try Data(contentsOf: file) == corrupt, "a failed transaction changed the existing file")
            try saved.write(to: file, options: .atomic)
            require(try registry.snapshot().count == 31, "a recovered registry still failed or lost receipts")
        }
        print("PASS concurrent transactions, stale snapshots, unverified copies and recovery from read failures")

        // Five requests overlap, app 5 starts when app 3 finishes while app 0
        // is still waiting, and each slot reuses the same thread/client.
        do {
            let (apps, registry) = try fixture(12)
            let batch = IDeviceUninstallBatch(apps: apps + [apps[0]], registry: registry)
            let task = run(batch, concurrency: 99)
            try await waitUntil("five removals did not overlap") { device.read { $0.commands.count == 5 } }
            require(batch.results.isEmpty, "a gated command completed")
            device.release(apps[3].id)
            try await waitUntil("free slot waited for an earlier app") { device.read { $0.commands.count == 6 } }
            let commands = device.read { $0.commands }
            require(commands[5].client == commands.first(where: { $0.id == apps[3].id })!.client, "slot did not reuse client")
            require(batch.results[apps[0].id] == nil, "oldest command should still be active")
            device.releaseAll(); try await task.value
            require(batch.results.count == 12, "duplicate or missing batch results")
            require(device.read { $0.peak == 5 && $0.opened == 5 && $0.closed == 5 }, "batch exceeded limit or reopened clients")
            require(try registry.snapshot().isEmpty, "confirmed removals retained receipts")
        }
        print("PASS five in flight, rolling refill, client/thread reuse and duplicate selection")

        do {
            let (apps, registry) = try fixture(9)
            let batch = IDeviceUninstallBatch(apps: apps, registry: registry)
            let task = run(batch)
            try await waitUntil("stop fixture did not start") { device.read { $0.commands.count == 5 } }
            batch.stop(); device.releaseAll(); try await task.value
            require(device.read { $0.commands.count == 5 && $0.closed == 5 }, "stop admitted more work or leaked active clients")
            let receipts = try registry.snapshot()
            require(batch.results.count == 5 && receipts.count == 4, "stop changed pending apps")
        }
        print("PASS stop drains active removals and preserves pending apps")

        do {
            let (apps, registry) = try fixture(3)
            device.reset(apps, behavior: [apps[0].id: .disconnected])
            let batch = IDeviceUninstallBatch(apps: apps, registry: registry)
            device.releaseAll(); try await run(batch, concurrency: 1).value
            require(device.read { $0.commands.map(\.id) == apps.map(\.id) && $0.opened == 2 && $0.closed == 2 }, "transport failure replayed a deletion or reused broken stream")
            require((try registry.snapshot()).map(\.bundleIdentifier) == [apps[0].id], "ambiguous removal lost its receipt")
        }
        print("PASS transport failure discards stream without replay or receipt loss")

        do {
            let (apps, registry) = try fixture(6)
            device.reset(apps, behavior: [apps[0].id: .reject, apps[1].id: .stillInstalled])
            device.read { $0.apps[apps[2].id] = nil }
            // A changed installed copy must fail validation before any command.
            device.read {
                $0.omittedFromLookup.insert(apps[5].id)
                $0.apps[apps[3].id] = IDeviceInstalledApp(bundleIdentifier: apps[3].id, name: "Replacement", version: "2",
                    applicationIdentifier: "OTHER.test", installationPath: "/new-copy", applicationType: "User", isRemovable: true)
            }
            let batch = IDeviceUninstallBatch(apps: apps, registry: registry)
            let suite = UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set([apps[4].id: apps[4].name], forKey: "Ksign.uninstallBlacklist")
            device.releaseAll()
            try await run(batch, concurrency: 1, check: { id in
                try UninstallBlacklist.checkSavedRemovalAllowed(for: id, defaults: UserDefaults(suiteName: suite)!)
            }).value
            require(device.read { $0.commands.map(\.id) == [apps[0].id, apps[1].id] && $0.opened == 1 }, "validation/blacklist sent a command or rejection discarded usable stream")
            require((try registry.snapshot()).count == 5, "failed removals lost receipts or absent app retained one")
            guard case .success(false) = batch.results[apps[2].id] else { fatalError("absent app not recognized") }
        }
        print("PASS rejection, absence verification, already absent, copy binding and final blacklist check")

        do {
            let (apps, registry) = try fixture(8)
            let batch = IDeviceUninstallBatch(apps: apps, registry: registry)
            let task = run(batch)
            try await waitUntil("cancel fixture did not start") { device.read { $0.commands.count == 5 } }
            task.cancel(); device.releaseAll(); try await task.value
            require(batch.results.count == 5 && device.read { $0.closed == 5 && $0.commands.count == 5 }, "cancellation abandoned active commands")
            require((try registry.snapshot()).count == 3, "cancellation did not record confirmed removals")
        }
        print("PASS task cancellation drains committed commands")

        do {
            let (apps, registry) = try fixture(6)
            let manager = DeviceInstallationManager(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                legacyPairingExists: { false }, canCreatePairing: { true })
            manager.mode = .builtIn
            let workflow = UUID()
            manager.retainWorkflow(workflow)
            let batch = IDeviceUninstallBatch(apps: apps, registry: registry)
            let removal = Task { try await manager.uninstall(batch, onEvent: { _ in }) }
            try await waitUntil("manager still serialized removals") { device.read { $0.commands.count == 5 } }
            let resets = HeartbeatManager.shared.resets
            let installation = Task {
                try await manager.install(at: URL(fileURLWithPath: "/tmp/test.ipa"), viewModel: InstallerStatusViewModel(),
                    suspend: false, mode: .builtIn)
            }
            await Task.yield()
            require(!device.read { $0.installStarted }, "install entered an active removal batch")
            device.releaseAll(); try await removal.value; try await installation.value
            require(device.read { $0.installStarted && $0.closed == 5 }, "install did not resume after removals")
            require(HeartbeatManager.shared.resets == resets, "working batch rebuilt its tunnel")
            manager.releaseWorkflow(workflow)
            try await waitUntil("manager did not release connection") { manager.canReconnectVPN }
        }
        print("PASS manager reserves the batch and reuses the prepared tunnel")

        do {
            let (apps, _) = try fixture(9, registry: .shared)
            let manager = DeviceInstallationManager.shared
            manager.mode = .builtIn
            let model = InstalledAppsModel()
            model.load()
            try await waitUntil("model failed to load") { !model.isLoading }
            require(model.apps.count == apps.count, "model inventory mismatch")
            require(model.uninstall(apps), "model rejected batch")
            try await waitUntil("model batch did not overlap") { device.read { $0.commands.count == 5 } }
            device.release(apps[3].id)
            try await waitUntil("model did not refill") { device.read { $0.commands.count == 6 } }
            try await waitUntil("model did not report out-of-order completion") { model.uninstallCompleted == 1 }
            model.stopUninstalling(); device.releaseAll()
            try await waitUntil("model did not finish") { !model.isUninstalling }
            require(model.uninstallCompleted == 6 && model.apps.count == 3, "model lost/doubled out-of-order results")
            require(apps.dropFirst(6).allSatisfy { model.uninstallStatuses[$0.id] == "Not started" }, "model marked a pending app completed")
            require(model.uninstallActiveCount == 0 && model.uninstallSummary == "Stopped. Uninstalled 6 of 9 apps.", "model summary incorrect")
            try await waitUntil("model did not release connection") { manager.canReconnectVPN }
        }
        print("PASS model progress, out-of-order stop results and cleanup")

        do {
            let (apps, registry) = try fixture(4, registry: .shared)
            device.read {
                $0.apps[apps[1].id] = nil
                $0.omittedFromInventory = [apps[0].id, apps[2].id, apps[3].id]
                $0.omittedFromLookup = [apps[0].id, apps[3].id]
                $0.localPresence = [apps[0].id: true, apps[1].id: false]
            }
            let model = InstalledAppsModel()
            model.load()
            try await waitUntil("model did not finish incomplete inventory") { !model.isLoading }
            require(model.apps.first { $0.id == apps[0].id }?.trackingRestriction != nil,
                "an installed app skipped by both remote queries disappeared")
            require(!model.apps.contains { $0.id == apps[1].id }, "a corroborated absence did not clear its record")
            require(model.apps.contains { $0.id == apps[2].id && $0.trackingRestriction == nil },
                "targeted lookup did not recover a copy omitted from inventory")
            require(model.apps.first { $0.id == apps[3].id }?.trackingRestriction != nil,
                "an unavailable local presence answer cleared a receipt")
            require(try !registry.snapshot().contains { $0.bundleIdentifier == apps[1].id },
                "the absent record survived on disk")
        }
        print("PASS refresh uses targeted lookup and independent local absence before pruning")
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', default=shutil.which('swiftc'))
    args = parser.parse_args()
    if not args.swiftc:
        parser.error('pass --swiftc /path/to/swiftc')
    with tempfile.TemporaryDirectory(prefix='ksign-uninstall-') as tmp:
        directory = Path(tmp)
        native = ROOT / 'Native/Device'
        proxy = (native / 'InstallationProxy.swift').read_text()
        methods = proxy[proxy.index('    public func installedApps()'):proxy.index('    // Each proxy is one attempt.')]
        registry = (native / 'ManagedInstallRegistry.swift').read_text()
        # Substitute only the platform's persistent shared-storage location.
        start = registry.index('    public static let shared =')
        end = registry.index('\n\n', start)
        registry = registry[:start] + '''    public static let shared = IDeviceManagedInstallRegistry(fileURL:
        URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("shared-receipts.json"))''' + registry[end:]
        sources = [STUBS + methods + '\n}\n', registry]
        sources += [(native / name).read_text() for name in (
            'InstalledApps.swift', 'UninstallRequest.swift', 'IDeviceInstallationWorker.swift')]
        sources.append('extension IDeviceInstalledApp: Encodable {}')
        sources += [(ROOT / 'Asign/Backend/Device' / name).read_text() for name in (
            'DeviceUninstallSelection.swift', 'UninstallBlacklist.swift', 'DeviceInstallationManager.swift', 'InstalledAppsModel.swift')]
        source = '\n'.join(sources) + TESTS
        for module in ('Combine', 'IDeviceSwift', 'NimbleExtensions', 'UIKit'):
            source = source.replace(f'import {module}\n', '')
        harness = directory / 'Harness.swift'
        harness.write_text(source)
        executable = directory / 'checks'
        subprocess.run([args.swiftc, '-swift-version', '5', '-parse-as-library', str(harness), '-o', str(executable)], check=True)
        env = dict(os.environ, XDG_CONFIG_HOME=str(directory / 'config'), XDG_DATA_HOME=str(directory / 'data'))
        subprocess.run([str(executable), str(directory)], env=env, check=True, timeout=60)


if __name__ == '__main__':
    main()

import Foundation

// Framework/service doubles. The runner compiles the actual connection manager
// and VPN implementation against these, without contacting a device or Keychain.
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
protocol ObservableObject {}
enum NEVPNStatus { case invalid, disconnected, connecting, connected, reasserting, disconnecting }
class NEVPNProtocol {}
final class NETunnelProviderProtocol: NEVPNProtocol {
    var providerBundleIdentifier: String?
    var serverAddress: String?
    var disconnectOnSleep = true
}
final class FakeVPNConnection {
    var status = NEVPNStatus.disconnected
    var starts = 0
    var stops = 0
    var delayStop = false
    func startVPNTunnel() throws { starts += 1; status = .connected }
    func stopVPNTunnel() { stops += 1; status = delayStop ? .disconnecting : .disconnected }
}
final class NETunnelProviderManager {
    static var configurations: [NETunnelProviderManager] = []
    let connection = FakeVPNConnection()
    var protocolConfiguration: NEVPNProtocol?
    var localizedDescription: String?
    var isEnabled = true
    var isOnDemandEnabled = false
    var saves = 0
    var saveError: Error?
    static func loadAllFromPreferences(completionHandler: ([NETunnelProviderManager]?, Error?) -> Void) {
        completionHandler(configurations, nil)
    }
    func saveToPreferences(completionHandler: (Error?) -> Void) { saves += 1; completionHandler(saveError) }
    func loadFromPreferences(completionHandler: (Error?) -> Void) { completionHandler(nil) }
}
struct DeviceSetupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
struct DevicePairingRecord { let identity: String }
enum DevicePairingStore {
    static var record: DevicePairingRecord?
    static var loadError: Error?
    static func load() throws -> DevicePairingRecord? {
        if let loadError { throw loadError }
        return record
    }
    static func save(_ value: DevicePairingRecord) throws { record = value }
    static func reset() throws { record = nil }
    static func removeWorkingCopy() {}
    static func materialize(_ record: DevicePairingRecord) throws -> URL {
        URL(fileURLWithPath: "/pairing/\(record.identity).plist")
    }
}
@MainActor final class DevicePairingService {
    static let shared = DevicePairingService()
    var calls = 0
    var failure: Error?
    func pair() async throws -> DevicePairingRecord {
        calls += 1
        if let failure { throw failure }
        return DevicePairingRecord(identity: "replacement")
    }
    func cancel() {}
}
@MainActor final class HeartbeatManager {
    static let shared = HeartbeatManager()
    static var pairingPath: String?
    var outcomes: [Error?] = []
    var attempts: [String?] = []
    func resetInstallationConnection() async {}
    static func configurePairingPath(_ path: String?) { pairingPath = path }
    func prepareInstallationConnection() async throws {
        attempts.append(Self.pairingPath)
        if !outcomes.isEmpty, let error = outcomes.removeFirst() { throw error }
    }
}
final class InstallerStatusViewModel {}
@MainActor final class InstallationProxy {
    static var calls = 0
    static var failure: Error?
    static var holdInstalls = false
    static var pending: [String: CheckedContinuation<Void, Error>] = [:]
    init(viewModel: InstallerStatusViewModel) {}
    func install(at url: URL, suspend: Bool, isCurrent: @escaping () -> Bool) async throws {
        Self.calls += 1
        if let failure = Self.failure { throw failure }
        if Self.holdInstalls {
            try await withCheckedThrowingContinuation { Self.pending[url.lastPathComponent] = $0 }
        }
        try Task.checkCancellation()
    }
}

@main struct ConnectionRecoveryTests {
    @MainActor static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    @MainActor static func fixture(legacy: Bool = false, canPair: Bool = true,
                                   saved: Bool = true) -> (DeviceInstallationManager, NETunnelProviderManager, UserDefaults) {
        DevicePairingStore.record = saved ? DevicePairingRecord(identity: "original") : nil
        DevicePairingStore.loadError = nil
        DevicePairingService.shared.calls = 0
        DevicePairingService.shared.failure = nil
        HeartbeatManager.shared.outcomes = []
        HeartbeatManager.shared.attempts = []
        InstallationProxy.calls = 0
        InstallationProxy.failure = nil
        precondition(InstallationProxy.pending.isEmpty)
        InstallationProxy.holdInstalls = false
        let manager = NETunnelProviderManager()
        let config = NETunnelProviderProtocol()
        config.providerBundleIdentifier = "test.ksign.tunnel"
        config.serverAddress = "On this device"
        config.disconnectOnSleep = false
        manager.protocolConfiguration = config
        manager.connection.status = .connected
        NETunnelProviderManager.configurations = [manager]
        let defaults = UserDefaults(suiteName: "Ksign.ConnectionRecoveryTests")!
        defaults.removePersistentDomain(forName: "Ksign.ConnectionRecoveryTests")
        defaults.set("builtIn", forKey: "Ksign.deviceConnectionMode")
        let vpn = LocalDeviceVPN(extensionIdentifier: { "test.ksign.tunnel" })
        let installer = DeviceInstallationManager(vpn: vpn, defaults: defaults,
            vpnReconnect: VPNReconnectCoordinator(defaults: defaults),
            legacyPairingExists: { legacy }, canCreatePairing: { canPair })
        return (installer, manager, defaults)
    }

    @MainActor static func settle() async {
        // Let cleanup scheduled by enqueue finish before resetting the doubles.
        for _ in 0..<20 { await Task.yield() }
    }

    @MainActor static func main() async throws {
        let reset = DeviceSetupError("Socket(Os { code: 54, kind: ConnectionReset, message: Connection reset by peer })")

        var (installer, tunnel, defaults) = fixture()
        await installer.setUp()
        await settle()
        expect(HeartbeatManager.shared.attempts.count == 1, "Healthy connections should connect once")
        expect(DevicePairingService.shared.calls == 0, "Preserve working pairing across updates")
        expect(tunnel.connection.stops == 0, "Leave a healthy adopted VPN running")

        (installer, tunnel, defaults) = fixture()
        HeartbeatManager.shared.outcomes = [reset, nil]
        await installer.setUp()
        await settle()
        expect(HeartbeatManager.shared.attempts.count == 2, "Retry handshake after tunnel restart")
        expect(tunnel.connection.starts == 1 && tunnel.saves == 1, "Restart and refresh saved VPN preferences")
        expect(DevicePairingService.shared.calls == 0, "Tunnel recovery must retain credentials")

        (installer, tunnel, defaults) = fixture()
        HeartbeatManager.shared.outcomes = [reset, reset, nil]
        await installer.setUp()
        await settle()
        expect(DevicePairingService.shared.calls == 1, "Repair stale saved pairing once")
        expect(HeartbeatManager.shared.attempts.last! == "/pairing/replacement.plist", "Connect with repaired credentials")
        expect(DevicePairingStore.record?.identity == "replacement", "Persist successful replacement pairing")

        (installer, tunnel, defaults) = fixture(legacy: true, saved: false)
        HeartbeatManager.shared.outcomes = [reset, reset, nil]
        await installer.setUp()
        await settle()
        expect(HeartbeatManager.shared.attempts.first! == nil, "Try compatible imported pairing first")
        expect(DevicePairingService.shared.calls == 1, "Recover from stale legacy pairing on upgrade")
        expect(HeartbeatManager.shared.attempts.last! == "/pairing/replacement.plist", "Stop falling back to legacy credentials")

        (installer, tunnel, defaults) = fixture(legacy: true)
        await installer.resetPairing()
        expect(defaults.bool(forKey: "Ksign.needsFreshBuiltInPairing"), "Remember an explicit pairing reset")
        // Simulate relaunch between forgetting and setting up, with the imported
        // file still present and the old extension still reporting connected.
        installer = DeviceInstallationManager(vpn: LocalDeviceVPN(extensionIdentifier: { "test.ksign.tunnel" }),
            defaults: defaults, legacyPairingExists: { true }, canCreatePairing: { true })
        await installer.setUp()
        await settle()
        expect(DevicePairingService.shared.calls == 1, "Forget must pair fresh even with an imported file")
        expect(HeartbeatManager.shared.attempts.first! == "/pairing/replacement.plist", "Never try forgotten legacy pairing")
        expect(tunnel.connection.starts == 1, "Explicit reset restarts an adopted VPN")
        expect(!defaults.bool(forKey: "Ksign.needsFreshBuiltInPairing"), "Clear reset request after pairing succeeds")

        (installer, tunnel, defaults) = fixture()
        HeartbeatManager.shared.outcomes = [reset, reset]
        DevicePairingService.shared.failure = CancellationError()
        await installer.setUp()
        await settle()
        expect(DevicePairingStore.record?.identity == "original", "Cancelled repair must preserve saved credentials")
        expect(HeartbeatManager.shared.attempts.count == 2, "Do not connect after pairing cancellation")

        (installer, tunnel, defaults) = fixture()
        HeartbeatManager.shared.outcomes = [CancellationError()]
        await installer.setUp()
        await settle()
        expect(tunnel.connection.starts == 0 && DevicePairingService.shared.calls == 0, "Cancellation must not trigger recovery")

        (installer, tunnel, defaults) = fixture(canPair: false)
        HeartbeatManager.shared.outcomes = [reset, reset]
        await installer.setUp()
        await settle()
        expect(DevicePairingService.shared.calls == 0, "Older iOS must not try unsupported pairing")
        if case .failed(let message) = installer.phase {
            expect(message.contains("Import a fresh pairing file"), "Explain manual recovery on older iOS")
        } else { preconditionFailure("Expected recoverable setup failure") }

        (installer, tunnel, defaults) = fixture(saved: false)
        HeartbeatManager.shared.outcomes = [reset, reset]
        await installer.setUp()
        await settle()
        expect(DevicePairingService.shared.calls == 1, "Never loop into repeated PIN prompts for a fresh pairing")
        expect(HeartbeatManager.shared.attempts.count == 2, "Bound connection retries")

        (installer, tunnel, defaults) = fixture()
        DevicePairingStore.loadError = DeviceSetupError("Keychain locked")
        await installer.setUp()
        await settle()
        expect(DevicePairingService.shared.calls == 0, "Keychain access failure must not replace credentials")

        (installer, tunnel, defaults) = fixture()
        HeartbeatManager.shared.outcomes = [reset, nil]
        InstallationProxy.failure = reset
        do {
            try await installer.install(at: URL(fileURLWithPath: "/app.ipa"),
                viewModel: InstallerStatusViewModel(), suspend: false, mode: .builtIn)
            preconditionFailure("Installation should fail")
        } catch {}
        await settle()
        expect(InstallationProxy.calls == 1, "Never replay an installation after a socket error")
        expect(DevicePairingService.shared.calls == 0, "Install errors must not trigger pairing repair")

        (installer, tunnel, defaults) = fixture()
        let foreign = NETunnelProviderManager()
        let foreignConfig = NETunnelProviderProtocol()
        foreignConfig.providerBundleIdentifier = "another.app.tunnel"
        foreign.protocolConfiguration = foreignConfig
        foreign.connection.status = .connected
        NETunnelProviderManager.configurations.insert(foreign, at: 0)
        HeartbeatManager.shared.outcomes = [reset, nil]
        await installer.setUp()
        await settle()
        expect(foreign.connection.stops == 0 && foreign.saves == 0, "Never alter another app's VPN configuration")

        (installer, tunnel, defaults) = fixture()
        (tunnel.protocolConfiguration as! NETunnelProviderProtocol).disconnectOnSleep = true
        await installer.setUp()
        await settle()
        expect(tunnel.saves == 1 && tunnel.connection.starts == 1, "Refresh outdated tunnel configuration before setup")

        (installer, tunnel, defaults) = fixture(legacy: true, saved: false)
        await installer.setUp()
        await settle()
        expect(DevicePairingService.shared.calls == 0, "Preserve a working imported pairing")
        expect(HeartbeatManager.shared.attempts.count == 1, "Healthy imported credentials need no retry")

        (installer, tunnel, defaults) = fixture()
        HeartbeatManager.shared.outcomes = [reset]
        tunnel.saveError = DeviceSetupError("VPN permission denied")
        await installer.setUp()
        await settle()
        expect(DevicePairingService.shared.calls == 0, "VPN permission failure must not trigger a PIN prompt")
        expect(DevicePairingStore.record?.identity == "original", "Keep credentials if VPN repair fails")

        (installer, tunnel, defaults) = fixture(legacy: true)
        await installer.resetPairing()
        DevicePairingService.shared.failure = CancellationError()
        await installer.setUp()
        await settle()
        expect(defaults.bool(forKey: "Ksign.needsFreshBuiltInPairing"), "Cancelled fresh pairing must retain the reset request")
        expect(HeartbeatManager.shared.attempts.isEmpty, "Do not fall back to imported credentials after cancellation")
        DevicePairingService.shared.failure = nil
        await installer.setUp()
        await settle()
        expect(DevicePairingService.shared.calls == 2, "Retry Setup should allow a new pairing attempt")
        expect(HeartbeatManager.shared.attempts.first! == "/pairing/replacement.plist", "Retry Setup still avoids forgotten pairing")

        print("Passed 16 device connection recovery scenarios")
        await settle()
        try await runConcurrencyTests()
        try await runVPNReconnectTests()
        defaults.removePersistentDomain(forName: "Ksign.ConnectionRecoveryTests")
    }
}

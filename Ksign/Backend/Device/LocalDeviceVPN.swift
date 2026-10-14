import Foundation
import NetworkExtension

@MainActor
final class LocalDeviceVPN {
    private var manager: NETunnelProviderManager?
    private var startedByKsign = false
    // Keep this through failure/cancellation cleanup so the final handoff can
    // still restore the user's VPN after an unsuccessful installation.
    private var restorationNeeded = false
    private let extensionIdentifier: @MainActor () -> String?

    init(extensionIdentifier: @escaping @MainActor () -> String? = { LocalDeviceVPN.extensionBundleIdentifier }) {
        self.extensionIdentifier = extensionIdentifier
    }

    static var extensionBundleIdentifier: String? {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let urls = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else { return nil }
        return urls.compactMap { Bundle(url: $0) }.first {
            $0.object(forInfoDictionaryKey: "KsignLocalDeviceTunnel") as? Bool == true
        }?.bundleIdentifier
    }

    var isConnected: Bool { manager?.connection.status == .connected }

    func connect(restarting: Bool = false) async throws {
        try Task.checkCancellation()
        guard let extensionID = extensionIdentifier() else {
            throw DeviceSetupError("This Ksign build does not include the local VPN extension. Update Ksign, or select Manual Setup.")
        }
        do {
            let configurations: [NETunnelProviderManager] = try await withCheckedThrowingContinuation { continuation in
                NETunnelProviderManager.loadAllFromPreferences { managers, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: managers ?? []) }
                }
            }
            try Task.checkCancellation()
            let manager = configurations.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == extensionID
            } ?? NETunnelProviderManager()
            self.manager = manager
            let existing = manager.protocolConfiguration as? NETunnelProviderProtocol
            let needsConfiguration = existing?.providerBundleIdentifier != extensionID ||
                existing?.serverAddress != "On this device" || existing?.disconnectOnSleep != false ||
                !manager.isEnabled || manager.isOnDemandEnabled
            if restarting || needsConfiguration {
                // An app update can leave the previous extension running. Only
                // stop the configuration matched to this build's extension ID.
                manager.connection.stopVPNTunnel()
                let deadline = Date().addingTimeInterval(20)
                while manager.connection.status != .disconnected && manager.connection.status != .invalid {
                    try Task.checkCancellation()
                    guard Date() < deadline else {
                        throw DeviceSetupError("The previous local VPN did not disconnect. Turn off Ksign Local Installation in VPN settings and retry setup.")
                    }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                try Task.checkCancellation()
                let config = NETunnelProviderProtocol()
                config.providerBundleIdentifier = extensionID
                config.serverAddress = "On this device"
                config.disconnectOnSleep = false
                manager.protocolConfiguration = config
                manager.localizedDescription = "Ksign Local Installation"
                manager.isEnabled = true
                manager.isOnDemandEnabled = false
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    manager.saveToPreferences { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    manager.loadFromPreferences { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
            }
            if manager.connection.status == .connected { return }
            try Task.checkCancellation()
            let deadline = Date().addingTimeInterval(20)
            while manager.connection.status == .disconnecting {
                try Task.checkCancellation()
                guard Date() < deadline else { throw DeviceSetupError("The previous VPN connection is still disconnecting. Try again in a moment.") }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            // If a previously started connection is still settling, wait for it.
            if manager.connection.status != .connecting && manager.connection.status != .reasserting {
                try manager.connection.startVPNTunnel()
                startedByKsign = true
                restorationNeeded = true
            }
            while manager.connection.status != .connected {
                try Task.checkCancellation()
                guard Date() < deadline else { throw DeviceSetupError("The local VPN did not connect. Check VPN permission and this build's signing profiles, then try again.") }
                if manager.connection.status == .invalid {
                    throw DeviceSetupError("The local VPN configuration is invalid. Reinstall Ksign with profiles that authorize Network Extensions.")
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        } catch is CancellationError {
            disconnectIfOwned()
            throw CancellationError()
        } catch {
            disconnectIfOwned()
            throw DeviceSetupError("Cannot start Ksign's local VPN. Allow the VPN configuration when asked. Ksign and its VPN extension must both be signed with profiles authorizing packet-tunnel-provider.\n\n\(error.localizedDescription)")
        }
    }

    func disconnectIfOwned() {
        if startedByKsign { manager?.connection.stopVPNTunnel() }
        startedByKsign = false
    }

    /// True only when this session started a tunnel and it has now stopped.
    func finishSession() async -> Bool {
        let shouldRestore = restorationNeeded
        restorationNeeded = false
        disconnectIfOwned()
        guard shouldRestore, let manager else { return false }
        let deadline = Date().addingTimeInterval(20)
        while manager.connection.status != .disconnected && manager.connection.status != .invalid {
            guard Date() < deadline else { return false }
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return false }
        }
        return true
    }
}

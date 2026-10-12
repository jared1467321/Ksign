import Foundation
import NetworkExtension

@MainActor
final class LocalDeviceVPN {
    private var manager: NETunnelProviderManager?
    private var startedByKsign = false

    static var extensionBundleIdentifier: String? {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let urls = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else { return nil }
        return urls.compactMap { Bundle(url: $0) }.first {
            $0.object(forInfoDictionaryKey: "KsignLocalDeviceTunnel") as? Bool == true
        }?.bundleIdentifier
    }

    var isConnected: Bool { manager?.connection.status == .connected }

    func connect() async throws {
        guard let extensionID = Self.extensionBundleIdentifier else {
            throw DeviceSetupError("This Ksign build does not include the local VPN extension. Update Ksign, or select Manual Setup.")
        }
        do {
            let configurations: [NETunnelProviderManager] = try await withCheckedThrowingContinuation { continuation in
                NETunnelProviderManager.loadAllFromPreferences { managers, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: managers ?? []) }
                }
            }
            let manager = configurations.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == extensionID
            } ?? NETunnelProviderManager()
            self.manager = manager
            if manager.connection.status == .connected { return }
            if manager.protocolConfiguration == nil || !manager.isEnabled {
                let config = NETunnelProviderProtocol()
                config.providerBundleIdentifier = extensionID
                config.serverAddress = "On this device"
                config.disconnectOnSleep = false
                manager.protocolConfiguration = config
                manager.localizedDescription = "Ksign Local Installation"
                manager.isEnabled = true
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
}

import Foundation
import NetworkExtension

@MainActor
final class LocalDeviceVPN {
    private var manager: NETunnelProviderManager?
    private var managesSession = false

    static var extensionBundleIdentifier: String? {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let urls = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else { return nil }
        return urls.compactMap { Bundle(url: $0) }.first {
            $0.object(forInfoDictionaryKey: "KsignLocalDeviceTunnel") as? Bool == true
        }?.bundleIdentifier
    }

    var isConnected: Bool { manager?.connection.status == .connected }
    var needsDisconnection: Bool { managesSession }

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
            // This is Ksign's own installation profile, including a connection
            // left running by an earlier process. Adopt it for this workflow so
            // it is also stopped afterward. Other apps' profiles are inaccessible.
            managesSession = true
            if manager.protocolConfiguration == nil || !manager.isEnabled || manager.isOnDemandEnabled {
                let config = NETunnelProviderProtocol()
                config.providerBundleIdentifier = extensionID
                config.serverAddress = "On this device"
                config.disconnectOnSleep = false
                manager.protocolConfiguration = config
                manager.localizedDescription = "Ksign Local Installation"
                manager.isEnabled = true
                manager.isOnDemandEnabled = false
                manager.onDemandRules = nil
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
            if manager.connection.status == .connected { return }
            let deadline = Date().addingTimeInterval(20)
            while manager.connection.status == .disconnecting {
                try Task.checkCancellation()
                guard Date() < deadline else { throw DeviceSetupError("The previous VPN connection is still disconnecting. Try again in a moment.") }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            // If a previously started connection is still settling, wait for it.
            if manager.connection.status != .connecting && manager.connection.status != .reasserting {
                try manager.connection.startVPNTunnel()
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
            try? await disconnectIfOwned()
            throw CancellationError()
        } catch {
            try? await disconnectIfOwned()
            throw DeviceSetupError("Cannot start Ksign's local VPN. Allow the VPN configuration when asked. Ksign and its VPN extension must both be signed with profiles authorizing packet-tunnel-provider.\n\n\(error.localizedDescription)")
        }
    }

    func disconnectIfOwned() async throws {
        guard managesSession, let manager else { return }
        // Cleanup must finish even when the install task that requested it was
        // cancelled. An unstructured task does not inherit that cancellation.
        let cleanup = Task { @MainActor in
            manager.connection.stopVPNTunnel()
            let deadline = Date().addingTimeInterval(10)
            while manager.connection.status != .disconnected && manager.connection.status != .invalid {
                guard Date() < deadline else {
                    throw DeviceSetupError("Ksign's installation VPN is still disconnecting. You can stop it in iOS VPN Settings.")
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                manager.loadFromPreferences { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            // Stopping only the tunnel leaves this profile selected/enabled.
            // Disable our profile without deleting it, preserving first-run
            // permission and allowing automatic re-enable on the next install.
            if manager.isEnabled || manager.isOnDemandEnabled {
                manager.isEnabled = false
                manager.isOnDemandEnabled = false
                manager.onDemandRules = nil
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    manager.saveToPreferences { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
            }
        }
        try await cleanup.value
        // Retain ownership on failure so a subsequent cleanup can retry.
        managesSession = false
    }
}

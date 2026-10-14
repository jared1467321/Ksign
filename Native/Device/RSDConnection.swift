import Foundation
import IDevice

final class RSDConnection {
    private let adapter: OpaquePointer
    private let handshake: OpaquePointer
    private let serviceConnectionLock = NSLock()
    init(adapter: OpaquePointer, handshake: OpaquePointer) {
        self.adapter = adapter
        self.handshake = handshake
    }

    // RSD connect functions borrow the adapter and handshake mutably. Protect
    // only service creation; each resulting client owns an independent stream
    // and can upload/install concurrently on its attempt's worker thread.
    func withServiceConnection<T>(_ body: (OpaquePointer, OpaquePointer) throws -> T) rethrows -> T {
        serviceConnectionLock.lock()
        defer { serviceConnectionLock.unlock() }
        return try body(adapter, handshake)
    }

    deinit {
        rsd_handshake_free(handshake)
        adapter_free(adapter)
    }
}

extension HeartbeatManager {
    // Independent of the legacy heartbeat restart lock.
    private static let connectionLock = NSLock()
    private static var connection: RSDConnection?
    private static var privatePairingPath: String?

    static var configuredPairingPath: String? {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return privatePairingPath
    }

    /// Called between install attempts. Existing leases survive replacement.
    public static func configurePairingPath(_ path: String?) {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        if privatePairingPath != path {
            connection = nil
            privatePairingPath = path
        }
    }

    public func invalidateRSDTunnel() {
        Self.connectionLock.lock()
        defer { Self.connectionLock.unlock() }
        Self.connection = nil
    }

    public func resetInstallationConnection() async {
        _ = try? await IDeviceInstallationWorker.shared.perform { self.invalidateRSDTunnel() }
    }

    public func prepareInstallationConnection() async throws {
        if !isRsd { start() }
        try await IDeviceInstallationWorker.shared.perform {
            if self.isRsd { _ = try self.acquireRSDConnection() }
            else {
                let deadline = Date().addingTimeInterval(10)
                while self.provider == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
                guard self.provider != nil, self.checkSocketConnection().isConnected else {
                    throw IDeviceSwiftError(message: "The local device connection is unavailable. Check your VPN and pairing file.")
                }
            }
        }
    }

    internal func acquireRSDConnection() throws -> RSDConnection {
        Self.connectionLock.lock()
        defer { Self.connectionLock.unlock() }
        if let connection = Self.connection { return connection }
        // Use the path directly: pairingFile() also acquires connectionLock.
        let path = Self.privatePairingPath ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
        let connection = try makeRSDConnection(pairingPath: path)
        Self.connection = connection
        return connection
    }

    private func makeRSDConnection(pairingPath path: String) throws -> RSDConnection {
        var pairing: OpaquePointer?
        if let error = rp_pairing_file_read(path, &pairing) {
            defer { idevice_error_free(error) }
            throw IDeviceSwiftError(error)
        }
        defer { rp_pairing_file_free(pairing) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port_rsd.bigEndian
        guard inet_pton(AF_INET, ipAddress, &address.sin_addr) == 1 else {
            throw IDeviceSwiftError(message: "Invalid local device address.")
        }
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        let error = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) {
                tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.size), "Ksign", pairing, nil, nil, &adapter, &handshake)
            }
        }
        if let error {
            defer { idevice_error_free(error) }
            throw IDeviceSwiftError(error)
        }
        guard let adapter, let handshake else {
            if let adapter { adapter_free(adapter) }
            if let handshake { rsd_handshake_free(handshake) }
            throw IDeviceSwiftError(message: "The device did not provide an installation connection.")
        }
        return RSDConnection(adapter: adapter, handshake: handshake)
    }
}

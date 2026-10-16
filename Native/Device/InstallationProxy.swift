import Foundation
import Combine
import UIKit
import IDevice

public enum IDeviceUploadSettings {
    public static let chunkSizeKey = "Ksign.deviceUploadChunkSizeMB"
    public static let lastUploadKey = "Ksign.lastDeviceUpload"
    public static let chunkSizesMB = [1, 2, 4, 8, 16]

    public static func chunkSizeMB(defaults: UserDefaults = .standard) -> Int {
        let saved = defaults.integer(forKey: chunkSizeKey)
        return chunkSizesMB.contains(saved) ? saved : 1
    }
}

public struct IDeviceUploadMetrics: Codable {
    public let bytes: UInt64
    public let duration: TimeInterval
    public let chunkSizeMB: Int

    public var averageMBPerSecond: Double {
        duration > 0 ? Double(bytes) / (1024 * 1024) / duration : 0
    }

    public var summary: String {
        String(format: "%.1f s · %.1f MB/s · %d MB chunks",
               duration, averageMBPerSecond, chunkSizeMB)
    }
}

// A completed error response from iOS's installer means the app was rejected,
// rather than the transport failing. Keep its original message for the row.
public struct IDeviceInstallationRejection: LocalizedError {
    private let message: String
    public var errorDescription: String? { message }
    init(message: String) { self.message = message }
}

public final class InstallationProxy: Identifiable, ObservableObject {
    public let viewModel: InstallerStatusViewModel
    private let cancellation = IDeviceInstallCancellation()
    private var isCurrent: () -> Bool = { true }

    public init(viewModel: InstallerStatusViewModel) { self.viewModel = viewModel }

    // Each proxy is one attempt. Cancellation waits for any native call already
    // in progress to return before releasing resources and its admission slot.
    public func install(at url: URL, suspend: Bool = false,
                        isCurrent: @escaping () -> Bool = { true }) async throws {
        self.isCurrent = isCurrent
        let chunkSizeMB = IDeviceUploadSettings.chunkSizeMB()
        update { $0.uploadMetrics = nil }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await IDeviceInstallationWorker.performInstallation { [self] in
                try cancellation.check()
                try installSynchronously(at: url, suspend: suspend, chunkSizeMB: chunkSizeMB)
            }
            try cancellation.check()
            await MainActor.run {
                if isCurrent() { viewModel.status = .completed(.success(())) }
            }
        } onCancel: { [cancellation] in cancellation.cancel() }
    }

    private func checkCancellation() throws {
        try cancellation.check()
        if !isCurrent() { throw CancellationError() }
    }

    private func update(_ action: @escaping (InstallerStatusViewModel) -> Void) {
        DispatchQueue.main.async { [self] in
            guard !cancellation.isCancelled, isCurrent() else { return }
            action(viewModel)
        }
    }

    private func check(_ error: UnsafeMutablePointer<IdeviceFfiError>?) throws {
        guard let error else { return }
        defer { idevice_error_free(error) }
        // Pinned idevice: InstallationProxy = 107, OperationFailed = 1.
        // Socket failures remain transport errors, even during installation.
        if error.pointee.code == 107 && error.pointee.sub_code == 1 {
            throw IDeviceInstallationRejection(message: IDeviceSwiftError(error).localizedDescription)
        }
        throw IDeviceSwiftError(error)
    }

    private func installSynchronously(at url: URL, suspend: Bool, chunkSizeMB: Int) throws {
        let heartbeat = HeartbeatManager.shared
        guard FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile()) else {
            throw IDeviceSwiftError(message: "Pair this device in Installation settings before installing.")
        }
        // Keep a lease on the workflow's shared tunnel until this attempt's
        // clients are freed. Per-app handles stay on this worker thread.
        let connection = heartbeat.isRsd ? try heartbeat.acquireRSDConnection() : nil
        defer { withExtendedLifetime(connection) {} }
        let provider = connection == nil ? try makeLegacyProvider(heartbeat) : nil
        defer { idevice_provider_free(provider) }
        try checkCancellation()
        var afc: OpaquePointer?
        var proxy: OpaquePointer?
        var file: OpaquePointer?
        var remotePath: String?
        defer {
            if let file { idevice_error_free(afc_file_close(file)) }
            if let remotePath { idevice_error_free(afc_remove_path(afc, remotePath)) }
            installation_proxy_client_free(proxy)
            afc_client_free(afc)
        }
        if let connection {
            try connection.withServiceConnection { adapter, handshake in
                try check(afc_client_connect_rsd(adapter, handshake, &afc))
            }
        } else {
            try check(afc_client_connect(provider, &afc))
        }
        // PublicStaging normally exists. Ignore only AFC's OBJECT_EXISTS status.
        if let error = afc_make_directory(afc, "PublicStaging") {
            defer { idevice_error_free(error) }
            guard error.pointee.sub_code == 16 else { throw IDeviceSwiftError(error) }
        }
        let stagingPath = "/PublicStaging/\(UUID().uuidString).ipa"
        remotePath = stagingPath
        try check(afc_file_open(afc, stagingPath, AfcWrOnly, &file))
        // Bound resident upload memory per admitted job, including files for
        // which Data.mappedIfSafe would fall back to loading the entire IPA.
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let byteCount = try input.seekToEnd()
        try input.seek(toOffset: 0)
        guard byteCount > 0 else { throw IDeviceSwiftError(message: "The IPA is empty.") }
        update { $0.packageProgress = 1; $0.status = .sendingPayload }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let chunkSize = UInt64(chunkSizeMB * 1024 * 1024)
        var offset: UInt64 = 0
        while offset < byteCount {
            try checkCancellation()
            let size = Int(min(chunkSize, byteCount - offset))
            let written = try autoreleasepool { () throws -> Int in
                guard let data = try input.read(upToCount: size), !data.isEmpty else {
                    throw IDeviceSwiftError(message: "The IPA ended before its upload completed.")
                }
                try data.withUnsafeBytes { bytes in
                    try check(afc_file_write(file, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count))
                }
                return data.count
            }
            offset += UInt64(written)
            let progress = Double(offset) / Double(byteCount)
            update { $0.uploadProgress = progress }
        }
        let closeResult = afc_file_close(file)
        file = nil // close consumes the handle, including on failure
        try check(closeResult)
        try checkCancellation()
        // Include the final AFC close acknowledgment, but exclude connection
        // setup and the subsequent iOS installation/verification phase.
        let metrics = IDeviceUploadMetrics(bytes: byteCount,
            duration: ProcessInfo.processInfo.systemUptime - startedAt, chunkSizeMB: chunkSizeMB)
        update {
            $0.uploadMetrics = metrics
            if let encoded = try? JSONEncoder().encode(metrics) {
                UserDefaults.standard.set(encoded, forKey: IDeviceUploadSettings.lastUploadKey)
            }
        }
        if let connection {
            try connection.withServiceConnection { adapter, handshake in
                try check(installation_proxy_connect_rsd(adapter, handshake, &proxy))
            }
        } else {
            try check(installation_proxy_connect(provider, &proxy))
        }
        update { $0.status = .installing }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if suspend {
            DispatchQueue.main.async { UIApplication.shared.perform(#selector(NSXPCConnection.suspend)) }
        }
        try check(installation_proxy_install_with_callback(proxy, stagingPath, nil, Self.progressCallback, context))
        try checkCancellation()
    }

    private func makeLegacyProvider(_ heartbeat: HeartbeatManager) throws -> OpaquePointer {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = heartbeat.port.bigEndian
        guard inet_pton(AF_INET, heartbeat.ipAddress, &address.sin_addr) == 1,
              let pairing = heartbeat.getPairing() else {
            throw IDeviceSwiftError(message: "The device pairing or address is unavailable.")
        }
        var provider: OpaquePointer?
        let error = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) {
                idevice_tcp_provider_new($0, pairing, "Ksign installation", &provider)
            }
        }
        // The constructor consumes pairing on success; the address and label
        // above are valid, so an error leaves that ownership with us.
        if let error {
            idevice_pairing_file_free(pairing)
            try check(error)
        }
        guard let provider else { throw IDeviceSwiftError(message: "Could not create the device connection.") }
        return provider
    }

    private static let progressCallback: @convention(c) (UInt64, UnsafeMutableRawPointer?) -> Void = { progress, context in
        guard let context else { return }
        let operation = Unmanaged<InstallationProxy>.fromOpaque(context).takeUnretainedValue()
        operation.update { $0.installProgress = min(1, Double(progress) / 100) }
    }
}

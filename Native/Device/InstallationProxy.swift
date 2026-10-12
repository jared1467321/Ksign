import Foundation
import Combine
import UIKit
import IDevice

public final class InstallationProxy: Identifiable, ObservableObject {
    public let viewModel: InstallerStatusViewModel
    private let cancellation = IDeviceInstallCancellation()
    private var isCurrent: () -> Bool = { true }

    public init(viewModel: InstallerStatusViewModel) { self.viewModel = viewModel }

    // Each proxy is one attempt. Cancellation waits for any native call already
    // in progress to return before releasing resources or admitting another IPA.
    public func install(at url: URL, suspend: Bool = false,
                        isCurrent: @escaping () -> Bool = { true }) async throws {
        self.isCurrent = isCurrent
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await IDeviceInstallationWorker.shared.perform { [self] in
                try cancellation.check()
                try installSynchronously(at: url, suspend: suspend)
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
        throw IDeviceSwiftError(error)
    }

    private func installSynchronously(at url: URL, suspend: Bool) throws {
        let heartbeat = HeartbeatManager.shared
        guard FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile()) else {
            throw IDeviceSwiftError(message: "Pair this device in Installation settings before installing.")
        }
        // A strong lease keeps the adapter alive even if another service requests
        // a reconnect. Setup is protected by a lock; in-progress is never ready.
        let connection = heartbeat.isRsd ? try heartbeat.acquireRSDConnection() : nil
        defer { withExtendedLifetime(connection) {} }
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
            try check(afc_client_connect_rsd(connection.adapter, connection.handshake, &afc))
        } else {
            guard heartbeat.checkSocketConnection().isConnected, let provider = heartbeat.provider else {
                throw IDeviceSwiftError(message: "The device connection is unavailable. Connect your local VPN and restart the heartbeat.")
            }
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
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty else { throw IDeviceSwiftError(message: "The IPA is empty.") }
        update { $0.packageProgress = 1; $0.status = .sendingPayload }
        var offset = 0
        while offset < data.count {
            try checkCancellation()
            let size = min(1024 * 1024, data.count - offset)
            try data.withUnsafeBytes { bytes in
                try check(afc_file_write(file, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset), size))
            }
            offset += size
            let progress = Double(offset) / Double(data.count)
            update { $0.uploadProgress = progress }
        }
        let closeResult = afc_file_close(file)
        file = nil // close consumes the handle, including on failure
        try check(closeResult)
        try checkCancellation()
        if let connection {
            try check(installation_proxy_connect_rsd(connection.adapter, connection.handshake, &proxy))
        } else {
            try check(installation_proxy_connect(heartbeat.provider, &proxy))
        }
        update { $0.status = .installing }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if suspend {
            DispatchQueue.main.async { UIApplication.shared.perform(#selector(NSXPCConnection.suspend)) }
        }
        try check(installation_proxy_install_with_callback(proxy, stagingPath, nil, Self.progressCallback, context))
        try checkCancellation()
    }

    private static let progressCallback: @convention(c) (UInt64, UnsafeMutableRawPointer?) -> Void = { progress, context in
        guard let context else { return }
        let operation = Unmanaged<InstallationProxy>.fromOpaque(context).takeUnretainedValue()
        operation.update { $0.installProgress = min(1, Double(progress) / 100) }
    }
}

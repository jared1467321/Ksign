import Foundation
import Combine
import UIKit
import IDevice

public struct IDeviceUploadMetrics: Codable {
    public static let storageKey = "Ksign.lastDeviceUpload"
    public let bytes: UInt64
    public let duration: TimeInterval

    public var averageMBPerSecond: Double {
        duration > 0 ? Double(bytes) / (1024 * 1024) / duration : 0
    }

    public var summary: String {
        String(format: "%.1f s · %.1f MB/s", duration, averageMBPerSecond)
    }
}

// Worker events for throughput admission. This is separate from observable UI
// progress so a busy/dismissed drawer cannot delay measurements or tuning.
public enum IDeviceUploadEvent: Sendable {
    case started
    case advanced(UInt64)
    case finished(success: Bool)
}

public enum IDeviceInstallEvent: Equatable, Sendable {
    case uploading, installing
    case progress(Double)
}

// A completed error response from iOS's installer means the app was rejected,
// rather than the transport failing. Keep its original message for the row.
public struct IDeviceInstallationRejection: LocalizedError {
    private let message: String
    public var errorDescription: String? { message }
    init(message: String) { self.message = message }
}

// Keep only the newest numeric samples while a main-queue delivery is pending.
// Status transitions bypass this mailbox; terminal delivery closes it so an old
// delayed sample cannot arrive after completion, failure, cancellation or retry.
final class IDeviceInstallProgress {
    private let lock = NSLock()
    private var upload: Double?
    private var install: Double?
    private var deliveryQueued = false
    private var finished = false

    func submit(upload: Double? = nil, install: Double? = nil, allowsDelivery: Bool = true) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        if let upload { self.upload = upload }
        if let install { self.install = install }
        guard allowsDelivery, !deliveryQueued else { return false }
        deliveryQueued = true
        return true
    }

    func drain(finishing: Bool = false, scheduled: Bool = false,
               delivering: Bool = true) -> (upload: Double?, install: Double?) {
        lock.lock()
        defer { lock.unlock() }
        if finishing { finished = true }
        // A phase-boundary flush must retain the outstanding delivery's slot.
        if scheduled { deliveryQueued = false }
        // Retain the newest samples while inactive, but release an expired
        // delivery slot so foreground updates can schedule normally again.
        guard delivering || finishing else { return (nil, nil) }
        let pending = (upload: upload, install: install)
        upload = nil
        install = nil
        return pending
    }
}

// One lifecycle observer for all native attempts. Numeric presentation sleeps
// while inactive; worker telemetry and phase/terminal statuses stay immediate.
final class IDeviceInstallPresentation {
    static let shared = IDeviceInstallPresentation()
    private let lock = NSLock()
    private var active = false
    private var deliveries: [UUID: () -> Void] = [:]
    private var observers: [NSObjectProtocol] = []

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    private init() {
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.setActive(false)
            })
        }
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.setActive(true)
        })
        DispatchQueue.main.async { [weak self] in
            self?.setActive(UIApplication.shared.applicationState == .active)
        }
    }

    func observe(_ delivery: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        deliveries[id] = delivery
        lock.unlock()
        return id
    }

    func remove(_ id: UUID) {
        lock.lock()
        deliveries.removeValue(forKey: id)
        lock.unlock()
    }

    private func setActive(_ value: Bool) {
        lock.lock()
        let resuming = value && !active
        active = value
        let pending = resuming ? Array(deliveries.values) : []
        lock.unlock()
        for delivery in pending { delivery() }
    }
}

public final class InstallationProxy: Identifiable, ObservableObject {
    public let viewModel: InstallerStatusViewModel
    private let cancellation = IDeviceInstallCancellation()
    private let progress = IDeviceInstallProgress()
    private var isCurrent: () -> Bool = { true }
    private var installObserver: ((IDeviceInstallEvent) -> Void)?
    private var presentationID: UUID?

    public init(viewModel: InstallerStatusViewModel) {
        self.viewModel = viewModel
    }

    deinit {
        if let presentationID { IDeviceInstallPresentation.shared.remove(presentationID) }
    }

    /// Read-only validation for the signing-to-installation handoff. No AFC
    /// client, staging file or install command is created by this operation.
    public func validate(_ preflight: IDeviceInstallPreflight) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await IDeviceInstallationWorker.performInstallation { [self] in
                try checkCancellation()
                let heartbeat = HeartbeatManager.shared
                let connection = heartbeat.isRsd ? try heartbeat.acquireRSDConnection() : nil
                defer { withExtendedLifetime(connection) {} }
                let provider = connection == nil ? try makeLegacyProvider(heartbeat) : nil
                defer { idevice_provider_free(provider) }
                try validatePreflight(preflight, connection: connection, provider: provider)
            }
        } onCancel: { [cancellation] in cancellation.cancel() }
    }

    /// Read installed user apps from iOS, without consulting the local library.
    public func installedApps() async throws -> [IDeviceInstalledApp] {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await IDeviceInstallationWorker.performInstallation { [self] in
                try checkCancellation()
                return try withDeviceClient { client in
                    var output: UnsafeMutablePointer<CChar>?
                    defer { ksign_pairing_string_free(output) }
                    try check(ksign_installation_list(client, &output))
                    try checkCancellation()
                    guard let output else {
                        throw IDeviceSwiftError(message: "iOS did not return an installed-app list. Refresh to try again.")
                    }
                    return try JSONDecoder().decode([IDeviceInstalledApp].self,
                        from: Data(String(cString: output).utf8))
                }
            }
        } onCancel: { [cancellation] in cancellation.cancel() }
    }

    /// Returns false when already absent. Once the command is sent, await its
    /// result even if cancelled: removal may already have committed on device.
    public func uninstall(_ request: IDeviceUninstallRequest) async throws -> Bool {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await IDeviceInstallationWorker.performInstallation { [self] in
                try checkCancellation()
                return try withDeviceClient { client in
                    let installed = try lookup(request.bundleIdentifier, client: client)
                    guard try request.validate(installed, hostBundleIdentifier: Bundle.main.bundleIdentifier) else {
                        try request.didRemove()
                        return false
                    }
                    try checkCancellation()
                    try check(installation_proxy_uninstall(client, request.bundleIdentifier, nil))
                    guard try lookup(request.bundleIdentifier, client: client) == nil else {
                        throw IDeviceInstallationRejection(message: "iOS reported completion, but the app is still installed. Check the Home Screen before trying again.")
                    }
                    try request.didRemove()
                    return true
                }
            }
        } onCancel: { [cancellation] in cancellation.cancel() }
    }

    // Each proxy is one attempt. Cancellation waits for any native call already
    // in progress to return before releasing resources and its admission slot.
    public func install(at url: URL, suspend: Bool = false,
                        preflight: IDeviceInstallPreflight? = nil,
                        isCurrent: @escaping () -> Bool = { true }) async throws {
        self.isCurrent = isCurrent
        installObserver = viewModel.nativeInstallObserver
        presentationID = IDeviceInstallPresentation.shared.observe { [weak self] in
            self?.flushProgress()
        }
        update { $0.uploadMetrics = nil }
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await IDeviceInstallationWorker.performInstallation { [self] in
                    try cancellation.check()
                    try installSynchronously(at: url, suspend: suspend, preflight: preflight)
                }
                try cancellation.check()
                await MainActor.run {
                    flushProgress(finishing: true)
                    if isCurrent() { viewModel.status = .completed(.success(())) }
                }
            } catch {
                await MainActor.run { flushProgress(finishing: true) }
                throw error
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

    private func updateProgress(upload: Double? = nil, install: Double? = nil) {
        guard !cancellation.isCancelled, isCurrent() else { return }
        if let install { installObserver?(.progress(install)) }
        guard progress.submit(upload: upload, install: install,
                              allowsDelivery: IDeviceInstallPresentation.shared.isActive) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            flushProgress(scheduled: true)
        }
    }

    // Main queue only. Flush final values before publishing a phase/terminal
    // status, and discard samples belonging to a cancelled or replaced attempt.
    private func flushProgress(finishing: Bool = false, scheduled: Bool = false) {
        let pending = progress.drain(finishing: finishing, scheduled: scheduled,
                                     delivering: IDeviceInstallPresentation.shared.isActive)
        guard !cancellation.isCancelled, isCurrent() else { return }
        if let upload = pending.upload, upload != viewModel.uploadProgress {
            viewModel.uploadProgress = upload
        }
        if let install = pending.install, install != viewModel.installProgress {
            viewModel.installProgress = install
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

    private func validatePreflight(_ preflight: IDeviceInstallPreflight,
                                   connection: RSDConnection?, provider: OpaquePointer?) throws {
        var client: OpaquePointer?
        defer { installation_proxy_client_free(client) }
        if let connection {
            try connection.withServiceConnection { adapter, handshake in
                try check(installation_proxy_connect_rsd(adapter, handshake, &client))
            }
        } else {
            try check(installation_proxy_connect(provider, &client))
        }
        try checkCancellation()
        let result = try lookup(preflight.bundleIdentifier, client: client)
        try checkCancellation()
        guard let installed = result else { return }
        guard installed.bundleIdentifier == preflight.bundleIdentifier else { return }
        try preflight.validateInstalledApplication(IDeviceInstalledApplication(
            bundleIdentifier: installed.bundleIdentifier, applicationIdentifier: installed.applicationIdentifier))
        try checkCancellation()
    }

    private func lookup(_ bundleIdentifier: String, client: OpaquePointer?) throws -> IDeviceInstalledApp? {
        var output: UnsafeMutablePointer<CChar>?
        defer { ksign_pairing_string_free(output) }
        try check(ksign_installation_lookup(client, bundleIdentifier, &output))
        guard let output else { return nil }
        var app = try JSONDecoder().decode(IDeviceInstalledApp.self,
            from: Data(String(cString: output).utf8))
        app.registrationDate = IDeviceInstalledAppDates.registrationDate(for: app.id)
        return app
    }

    // Keep the shared tunnel leased until the client has been freed. Native
    // client creation, use and destruction all happen on the same worker.
    private func withDeviceClient<T>(_ body: (OpaquePointer?) throws -> T) throws -> T {
        let heartbeat = HeartbeatManager.shared
        let connection = heartbeat.isRsd ? try heartbeat.acquireRSDConnection() : nil
        defer { withExtendedLifetime(connection) {} }
        let provider = connection == nil ? try makeLegacyProvider(heartbeat) : nil
        defer { idevice_provider_free(provider) }
        var client: OpaquePointer?
        defer { installation_proxy_client_free(client) }
        if let connection {
            try connection.withServiceConnection { adapter, handshake in
                try check(installation_proxy_connect_rsd(adapter, handshake, &client))
            }
        } else {
            try check(installation_proxy_connect(provider, &client))
        }
        try checkCancellation()
        return try body(client)
    }

    private func installSynchronously(at url: URL, suspend: Bool,
                                      preflight: IDeviceInstallPreflight?) throws {
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
        if let preflight {
            try validatePreflight(preflight, connection: connection, provider: provider)
        }
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
        installObserver?(.uploading)
        update { $0.packageProgress = 1; $0.status = .sendingPayload }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let reportUpload = viewModel.uploadObserver
        var uploadFinished = false
        reportUpload?(.started)
        defer { if !uploadFinished { reportUpload?(.finished(success: false)) } }
        var offset: UInt64 = 0
        while offset < byteCount {
            try checkCancellation()
            let size = Int(min(1024 * 1024, byteCount - offset))
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
            reportUpload?(.advanced(offset))
            let progress = Double(offset) / Double(byteCount)
            updateProgress(upload: progress)
        }
        let closeResult = afc_file_close(file)
        file = nil // close consumes the handle, including on failure
        try check(closeResult)
        try checkCancellation()
        uploadFinished = true
        reportUpload?(.finished(success: true))
        // Include the final AFC close acknowledgment, but exclude connection
        // setup and the subsequent iOS installation/verification phase.
        let metrics = IDeviceUploadMetrics(bytes: byteCount,
            duration: ProcessInfo.processInfo.systemUptime - startedAt)
        update {
            $0.uploadMetrics = metrics
            if let encoded = try? JSONEncoder().encode(metrics) {
                UserDefaults.standard.set(encoded, forKey: IDeviceUploadMetrics.storageKey)
            }
        }
        if let connection {
            try connection.withServiceConnection { adapter, handshake in
                try check(installation_proxy_connect_rsd(adapter, handshake, &proxy))
            }
        } else {
            try check(installation_proxy_connect(provider, &proxy))
        }
        installObserver?(.installing)
        update {
            self.flushProgress()
            $0.status = .installing
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if suspend {
            DispatchQueue.main.async { UIApplication.shared.perform(#selector(NSXPCConnection.suspend)) }
        }
        try check(installation_proxy_install_with_callback(proxy, stagingPath, nil, Self.progressCallback, context))
        // This command has committed. Record it before checking cancellation,
        // which must not erase a successful install's ownership. Bookkeeping
        // failure must never retry an already-completed installation.
        if let preflight {
            do {
                if let installed = try lookup(preflight.bundleIdentifier, client: proxy) {
                    try IDeviceManagedInstallRegistry.shared.recordConfirmedInstall(installed)
                }
            } catch {
                NSLog("Asign couldn't record a completed install: %@", error.localizedDescription)
            }
        }
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
                idevice_tcp_provider_new($0, pairing, "Asign installation", &provider)
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
        operation.updateProgress(install: min(1, Double(progress) / 100))
    }
}

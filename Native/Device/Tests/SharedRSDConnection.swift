import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
func autoreleasepool<T>(invoking body: () throws -> T) rethrows -> T { try body() }
#endif

// Compile the production tunnel, proxy and workers against native FFI doubles.
// Hold uploads open to prove separate clients overlap on exactly one tunnel.
protocol ObservableObject {}
public final class InstallerStatusViewModel {
    enum Status { case sendingPayload, installing, completed(Result<Void, Error>) }
    var status: Status = .sendingPayload
    var packageProgress = 0.0
    var uploadPublications = 0
    var uploadProgress = 0.0 { didSet { uploadPublications += 1 } }
    var uploadMetrics: IDeviceUploadMetrics?
    var installPublications = 0
    var installProgress = 0.0 { didSet { installPublications += 1 } }
    var uploadObserver: ((IDeviceUploadEvent) -> Void)?
    var nativeInstallObserver: ((IDeviceInstallEvent) -> Void)?
}
final class UIApplication {
    static let shared = UIApplication()
    enum State { case active, inactive, background }
    var applicationState = State.active
    static let willResignActiveNotification = Notification.Name("inactive")
    static let didEnterBackgroundNotification = Notification.Name("background")
    static let didBecomeActiveNotification = Notification.Name("active")
    func perform(_ selector: String) {}
}
struct IdeviceFfiError { var code: Int32 = 0; var sub_code: Int32 = 0 }
struct IDeviceSwiftError: LocalizedError {
    let errorDescription: String?
    init(_ error: UnsafeMutablePointer<IdeviceFfiError>?) {
        errorDescription = "Native error \(error!.pointee.code)/\(error!.pointee.sub_code)"
    }
    init(message: String) { errorDescription = message }
}
typealias idevice_sockaddr = sockaddr_in
let LOCKDOWN_PORT = 62078
let AfcWrOnly = 3

final class HeartbeatManager {
    static let shared = HeartbeatManager()
    let isRsd = true
    let ipAddress = "127.0.0.1"
    let port: UInt16 = 62078
    let port_rsd: UInt16 = 49152
    var provider: OpaquePointer?
    static func pairingFile() -> String { configuredPairingPath! }
    func start() {}
    func checkSocketConnection() -> (isConnected: Bool, unused: Bool) { (true, false) }
    func getPairing() -> OpaquePointer? { nil }
}

final class NativeCalls {
    static let shared = NativeCalls()
    let condition = NSCondition()
    private var nextID = 1
    private var owners: [OpaquePointer: Thread] = [:]
    private var clients: [OpaquePointer: OpaquePointer] = [:]
    private var files: [OpaquePointer: OpaquePointer] = [:]
    private var connecting = false
    private var holdUploads = true
    private var uploads: Set<OpaquePointer> = []
    private var clientTunnels: Set<OpaquePointer> = []
    private var tunnelsCreated = 0
    private var tunnelsFreed = 0
    private var clientsCreated = 0
    private var clientsFreed = 0
    private var nextInstallationError: IdeviceFfiError?
    private var lookupIdentity: String?
    private var lookupIDs: [String] = []
    private var installationCalls = 0
    private var writeCounts: [Int] = []

    func recordWrite(_ count: Int) {
        condition.lock()
        writeCounts.append(count)
        condition.unlock()
    }
    func takeWriteCounts() -> [Int] {
        condition.lock()
        defer { condition.unlock() }
        let counts = writeCounts
        writeCounts.removeAll()
        return counts
    }

    func failNextInstallation(code: Int32, subCode: Int32) {
        condition.lock()
        defer { condition.unlock() }
        nextInstallationError = IdeviceFfiError(code: code, sub_code: subCode)
    }
    func installationResult() -> UnsafeMutablePointer<IdeviceFfiError>? {
        condition.lock()
        defer { condition.unlock() }
        installationCalls += 1
        guard let error = nextInstallationError else { return nil }
        nextInstallationError = nil
        let pointer = UnsafeMutablePointer<IdeviceFfiError>.allocate(capacity: 1)
        pointer.initialize(to: error)
        return pointer
    }

    func setLookupIdentity(_ identity: String?) {
        condition.lock()
        defer { condition.unlock() }
        lookupIdentity = identity
    }
    func lookup(_ client: OpaquePointer, id: String) -> UnsafeMutablePointer<CChar>? {
        use(client)
        condition.lock()
        defer { condition.unlock() }
        lookupIDs.append(id)
        return lookupIdentity.flatMap { strdup($0) }
    }
    func installCallCount() -> Int {
        condition.lock()
        defer { condition.unlock() }
        return installationCalls
    }
    func expectLookupIDs(_ ids: [String]) {
        condition.lock()
        defer { condition.unlock() }
        precondition(lookupIDs == ids, "Preflight must query only the incoming bundle")
    }

    func handle() -> OpaquePointer {
        condition.lock()
        defer { condition.unlock() }
        let handle = OpaquePointer(bitPattern: nextID)!
        nextID += 1
        return handle
    }
    func tunnel() -> OpaquePointer {
        let tunnel = handle()
        condition.lock()
        tunnelsCreated += 1
        condition.unlock()
        return tunnel
    }
    func freeTunnel() {
        condition.lock()
        tunnelsFreed += 1
        condition.broadcast()
        condition.unlock()
    }
    func connect(_ tunnel: OpaquePointer) -> OpaquePointer {
        condition.lock()
        precondition(!connecting, "Service creation must not alias mutable native handles")
        connecting = true
        condition.unlock()
        Thread.sleep(forTimeInterval: 0.01)
        let client = handle()
        condition.lock()
        connecting = false
        owners[client] = Thread.current
        clients[client] = tunnel
        clientTunnels.insert(tunnel)
        clientsCreated += 1
        condition.unlock()
        return client
    }
    func use(_ client: OpaquePointer) {
        condition.lock()
        defer { condition.unlock() }
        precondition(owners[client] === Thread.current, "Per-app handles must stay on their worker")
    }
    func freeClient(_ client: OpaquePointer?) {
        guard let client else { return }
        use(client)
        condition.lock()
        owners[client] = nil
        clients[client] = nil
        clientsFreed += 1
        condition.unlock()
    }
    func open(_ client: OpaquePointer) -> OpaquePointer {
        use(client)
        let file = handle()
        condition.lock()
        files[file] = client
        condition.unlock()
        return file
    }
    func write(_ file: OpaquePointer) {
        condition.lock()
        let client = files[file]!
        precondition(owners[client] === Thread.current)
        uploads.insert(client)
        condition.broadcast()
        while holdUploads { condition.wait() }
        condition.unlock()
    }
    func close(_ file: OpaquePointer) {
        condition.lock()
        let client = files.removeValue(forKey: file)!
        precondition(owners[client] === Thread.current)
        condition.unlock()
    }
    func releaseUploads() {
        condition.lock()
        holdUploads = false
        condition.broadcast()
        condition.unlock()
    }
    func waitForUploads(_ count: Int) {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while uploads.count < count {
            precondition(condition.wait(until: deadline), "Uploads did not overlap")
        }
        precondition(tunnelsCreated == 1 && clientTunnels.count == 1,
                     "All app installs must reuse the prepared tunnel")
    }
    func expectFreed(_ count: Int) {
        condition.lock()
        defer { condition.unlock() }
        precondition(tunnelsFreed == count, "Tunnel lease lifetime is incorrect")
    }
    func expectCleanClients(_ count: Int = 6, tunnelCount: Int = 1) {
        condition.lock()
        defer { condition.unlock() }
        precondition(clientsCreated == count && clientsFreed == count && files.isEmpty,
                     "Every app must release its own AFC and installation clients")
        precondition(clientTunnels.count == tunnelCount, "Installation clients must reuse the upload tunnel")
    }
}

func rp_pairing_file_read(_ path: String, _ pairing: inout OpaquePointer?) -> UnsafeMutablePointer<IdeviceFfiError>? {
    pairing = NativeCalls.shared.handle(); return nil
}
func rp_pairing_file_free(_ pairing: OpaquePointer?) {}
func tunnel_create_rppairing(_ address: UnsafePointer<idevice_sockaddr>, _ length: socklen_t,
                            _ label: String, _ pairing: OpaquePointer?, _ callback: OpaquePointer?,
                            _ context: OpaquePointer?, _ adapter: inout OpaquePointer?,
                            _ handshake: inout OpaquePointer?) -> UnsafeMutablePointer<IdeviceFfiError>? {
    adapter = NativeCalls.shared.tunnel()
    handshake = NativeCalls.shared.handle()
    return nil
}
func rsd_handshake_free(_ handshake: OpaquePointer?) {}
func adapter_free(_ adapter: OpaquePointer?) { NativeCalls.shared.freeTunnel() }
func idevice_error_free(_ error: UnsafeMutablePointer<IdeviceFfiError>?) {
    error?.deinitialize(count: 1)
    error?.deallocate()
}
func idevice_provider_free(_ provider: OpaquePointer?) {}
func idevice_pairing_file_free(_ pairing: OpaquePointer?) {}
func idevice_tcp_provider_new(_ address: UnsafePointer<idevice_sockaddr>,
                             _ pairing: OpaquePointer, _ label: String,
                             _ provider: inout OpaquePointer?) -> UnsafeMutablePointer<IdeviceFfiError>? { nil }
func afc_client_connect_rsd(_ adapter: OpaquePointer, _ handshake: OpaquePointer,
                            _ client: inout OpaquePointer?) -> UnsafeMutablePointer<IdeviceFfiError>? {
    client = NativeCalls.shared.connect(adapter); return nil
}
func installation_proxy_connect_rsd(_ adapter: OpaquePointer, _ handshake: OpaquePointer,
                                    _ client: inout OpaquePointer?) -> UnsafeMutablePointer<IdeviceFfiError>? {
    client = NativeCalls.shared.connect(adapter); return nil
}
func afc_client_connect(_ provider: OpaquePointer?, _ client: inout OpaquePointer?) -> UnsafeMutablePointer<IdeviceFfiError>? { nil }
func installation_proxy_connect(_ provider: OpaquePointer?, _ client: inout OpaquePointer?) -> UnsafeMutablePointer<IdeviceFfiError>? { nil }
func afc_make_directory(_ client: OpaquePointer?, _ path: String) -> UnsafeMutablePointer<IdeviceFfiError>? {
    NativeCalls.shared.use(client!); return nil
}
func afc_file_open(_ client: OpaquePointer?, _ path: String, _ mode: Int,
                   _ file: inout OpaquePointer?) -> UnsafeMutablePointer<IdeviceFfiError>? {
    file = NativeCalls.shared.open(client!); return nil
}
func afc_file_write(_ file: OpaquePointer?, _ data: UnsafePointer<UInt8>, _ count: Int) -> UnsafeMutablePointer<IdeviceFfiError>? {
    NativeCalls.shared.recordWrite(count)
    NativeCalls.shared.write(file!); return nil
}
func afc_file_close(_ file: OpaquePointer?) -> UnsafeMutablePointer<IdeviceFfiError>? {
    NativeCalls.shared.close(file!); return nil
}
func afc_remove_path(_ client: OpaquePointer?, _ path: String) -> UnsafeMutablePointer<IdeviceFfiError>? {
    NativeCalls.shared.use(client!); return nil
}
func afc_client_free(_ client: OpaquePointer?) { NativeCalls.shared.freeClient(client) }
func installation_proxy_client_free(_ client: OpaquePointer?) { NativeCalls.shared.freeClient(client) }
func ksign_installation_lookup(_ client: OpaquePointer?, _ id: String,
    _ output: inout UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<IdeviceFfiError>? {
    output = NativeCalls.shared.lookup(client!, id: id)
    return nil
}
func ksign_pairing_string_free(_ value: UnsafeMutablePointer<CChar>?) { free(value) }
func installation_proxy_install_with_callback(_ client: OpaquePointer?, _ path: String,
    _ options: OpaquePointer?, _ callback: @convention(c) (UInt64, UnsafeMutableRawPointer?) -> Void,
    _ context: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<IdeviceFfiError>? {
    NativeCalls.shared.use(client!)
    if let error = NativeCalls.shared.installationResult() { return error }
    callback(100, context)
    return nil
}

@main struct SharedRSDConnectionTests {
    static func main() async throws {
        let defaults = UserDefaults.standard
        let retiredChunkSizeKey = "Ksign.deviceUploadChunkSizeMB"
        let previousChunkSize = defaults.object(forKey: retiredChunkSizeKey)
        let previousUpload = defaults.object(forKey: IDeviceUploadMetrics.storageKey)
        defer {
            defaults.set(previousChunkSize, forKey: retiredChunkSizeKey)
            defaults.set(previousUpload, forKey: IDeviceUploadMetrics.storageKey)
        }
        // Old installations may have saved 16 MB. Uploads must ignore that
        // retired preference and use the fixed, bounded 1 MiB write size.
        defaults.set(16, forKey: retiredChunkSizeKey)
        let oldResult = Data(#"{"bytes":1048576,"duration":1.0,"chunkSizeMB":16}"#.utf8)
        let decoded = try JSONDecoder().decode(IDeviceUploadMetrics.self, from: oldResult)
        precondition(decoded.bytes == 1048576 && decoded.averageMBPerSecond == 1)
        precondition(!decoded.summary.contains("chunks"), "Old results should display without chunk controls")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairing = directory.appendingPathComponent("pairing.plist")
        try Data().write(to: pairing)
        HeartbeatManager.configurePairingPath(pairing.path)
        try await HeartbeatManager.shared.prepareInstallationConnection()

        var attempts: [Task<Void, Error>] = []
        for index in 0..<3 {
            let ipa = directory.appendingPathComponent("app\(index).ipa")
            try Data(repeating: UInt8(index), count: 2 * 1024 * 1024 + 17).write(to: ipa)
            attempts.append(Task.detached {
                try await InstallationProxy(viewModel: InstallerStatusViewModel()).install(at: ipa)
            })
        }
        NativeCalls.shared.waitForUploads(3)
        await HeartbeatManager.shared.resetInstallationConnection()
        NativeCalls.shared.expectFreed(0)
        // Resetting the cache must not release a tunnel still leased by clients.
        try await HeartbeatManager.shared.prepareInstallationConnection()
        NativeCalls.shared.expectFreed(0)
        NativeCalls.shared.releaseUploads()
        for attempt in attempts { try await attempt.value }
        NativeCalls.shared.expectCleanClients()
        NativeCalls.shared.expectFreed(1)
        precondition(NativeCalls.shared.takeWriteCounts().sorted() ==
                     [17, 17, 17] + Array(repeating: 1024 * 1024, count: 6),
                     "Uploads must use 1 MiB chunks even when the retired setting is 16 MB")

        // Exercise classification through the production native error handler,
        // including a socket failure returned by the installation call itself.
        let ipa = directory.appendingPathComponent("app0.ipa")
        for (code, subCode, isRejection) in [(Int32(107), Int32(1), true), (1, 1, false), (107, 2, false)] {
            NativeCalls.shared.failNextInstallation(code: code, subCode: subCode)
            do {
                try await InstallationProxy(viewModel: InstallerStatusViewModel()).install(at: ipa)
                preconditionFailure("Expected native installation error")
            } catch {
                precondition((error is IDeviceInstallationRejection) == isRejection,
                             "Only a completed installer rejection can preserve the connection")
                precondition(error.localizedDescription == "Native error \(code)/\(subCode)",
                             "Preserve the original error message")
            }
        }
        try await InstallationProxy(viewModel: InstallerStatusViewModel()).install(at: ipa)
        NativeCalls.shared.expectCleanClients(14, tunnelCount: 2)
        _ = NativeCalls.shared.takeWriteCounts()
        let chunkBytes = 1024 * 1024
        let byteCount = chunkBytes * 2 + 123
        try Data(repeating: 42, count: byteCount).write(to: ipa)
        let model = InstallerStatusViewModel()
        let uploadEvents = UploadEventRecorder()
        let installEvents = InstallEventRecorder()
        model.uploadObserver = { uploadEvents.record($0) }
        model.nativeInstallObserver = { installEvents.record($0) }
        try await InstallationProxy(viewModel: model).install(at: ipa)
        precondition(NativeCalls.shared.takeWriteCounts() == [chunkBytes, chunkBytes, 123],
                     "Upload must preserve the final partial chunk")
        await MainActor.run {
            precondition(model.uploadProgress == 1 && model.installProgress == 1,
                         "Completion must flush final numeric progress immediately")
            precondition(model.uploadPublications < 3 && model.installPublications == 1,
                         "Fast transfers must coalesce UI updates, not queue one per chunk")
            guard let metrics = model.uploadMetrics else {
                preconditionFailure("Completed upload must report metrics")
            }
            precondition(metrics.bytes == UInt64(byteCount))
            precondition(metrics.duration > 0 && metrics.averageMBPerSecond.isFinite)
            let persisted = try! JSONDecoder().decode(IDeviceUploadMetrics.self,
                from: defaults.data(forKey: IDeviceUploadMetrics.storageKey)!)
            precondition(persisted.bytes == metrics.bytes && persisted.duration == metrics.duration)
        }
        uploadEvents.expectSuccessfulUpload(bytes: UInt64(byteCount))
        installEvents.expect([.uploading, .installing, .progress(1)])
        let publications = await MainActor.run { (model.uploadPublications, model.installPublications) }
        try await Task.sleep(nanoseconds: 250_000_000)
        await MainActor.run {
            precondition(model.uploadPublications == publications.0 && model.installPublications == publications.1,
                         "Delayed progress must not republish after terminal completion")
        }
        NativeCalls.shared.expectCleanClients(16, tunnelCount: 2)
        _ = NativeCalls.shared.takeWriteCounts()
        let beforeSkip = NativeCalls.shared.installCallCount()
        NativeCalls.shared.setLookupIdentity(#"{"bundleIdentifier":"app.test","applicationIdentifier":"STORE.app.test"}"#)
        let preflight = IDeviceInstallPreflight(bundleIdentifier: "app.test") { _ in
            throw IDeviceInstallSkip(reason: "Installed app conflict")
        }
        do {
            try await InstallationProxy(viewModel: InstallerStatusViewModel()).install(at: ipa, preflight: preflight)
            preconditionFailure("Conflicting apps must be skipped")
        } catch let skip as IDeviceInstallSkip {
            precondition(skip.reason == "Installed app conflict")
        }
        precondition(NativeCalls.shared.takeWriteCounts().isEmpty,
                     "A skipped app must not upload any IPA bytes")
        precondition(NativeCalls.shared.installCallCount() == beforeSkip,
                     "A skipped app must not send an install command")
        NativeCalls.shared.expectCleanClients(17, tunnelCount: 2)

        // Missing installed bundles and compatible updates proceed on the same tunnel.
        NativeCalls.shared.setLookupIdentity(nil)
        try await InstallationProxy(viewModel: InstallerStatusViewModel()).install(at: ipa, preflight: preflight)
        NativeCalls.shared.setLookupIdentity(#"{"bundleIdentifier":"app.test","applicationIdentifier":"TEAM.app.test"}"#)
        let compatible = IDeviceInstallPreflight(bundleIdentifier: "app.test") { installed in
            precondition(installed.applicationIdentifier == "TEAM.app.test")
        }
        try await InstallationProxy(viewModel: InstallerStatusViewModel()).install(at: ipa, preflight: compatible)
        precondition(NativeCalls.shared.installCallCount() == beforeSkip + 2)
        NativeCalls.shared.expectLookupIDs(["app.test", "app.test", "app.test"])
        NativeCalls.shared.expectCleanClients(23, tunnelCount: 2)
        let bytesBeforeValidation = NativeCalls.shared.takeWriteCounts()
        precondition(!bytesBeforeValidation.isEmpty)
        try await InstallationProxy(viewModel: InstallerStatusViewModel()).validate(compatible)
        precondition(NativeCalls.shared.takeWriteCounts().isEmpty,
                     "Signing handoff validation must not upload the package")
        precondition(NativeCalls.shared.installCallCount() == beforeSkip + 2,
                     "Signing handoff validation must not submit an install command")
        NativeCalls.shared.expectCleanClients(24, tunnelCount: 2)
        NativeCalls.shared.expectFreed(1)
        await HeartbeatManager.shared.resetInstallationConnection()
        NativeCalls.shared.expectFreed(2)
        HeartbeatManager.configurePairingPath(nil)
        print("Passed shared native tunnel, overlapping uploads, fixed upload size, upload metrics, installer error classification and lease cleanup")
    }
}

final class UploadEventRecorder {
    private let lock = NSLock()
    private var started = false
    private var bytes: UInt64 = 0
    private var finished = false
    func record(_ event: IDeviceUploadEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .started:
            precondition(!started)
            started = true
        case .advanced(let sent):
            precondition(started && !finished && sent > bytes)
            bytes = sent
        case .finished(let success):
            precondition(started && !finished && success)
            finished = true
        }
    }
    func expectSuccessfulUpload(bytes expected: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        precondition(started && finished && bytes == expected,
                     "Worker telemetry must count useful bytes independently of UI progress")
    }
}

final class InstallEventRecorder {
    private let lock = NSLock()
    private var events: [IDeviceInstallEvent] = []
    func record(_ event: IDeviceInstallEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }
    func expect(_ expected: [IDeviceInstallEvent]) {
        lock.lock()
        defer { lock.unlock() }
        precondition(events == expected,
                     "Worker phase and progress telemetry must remain ordered independently of UI delivery")
    }
}

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
    var uploadProgress = 0.0
    var uploadMetrics: IDeviceUploadMetrics?
    var installProgress = 0.0
}
final class UIApplication {
    static let shared = UIApplication()
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
        guard let error = nextInstallationError else { return nil }
        nextInstallationError = nil
        let pointer = UnsafeMutablePointer<IdeviceFfiError>.allocate(capacity: 1)
        pointer.initialize(to: error)
        return pointer
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
        let previousChunkSize = defaults.object(forKey: IDeviceUploadSettings.chunkSizeKey)
        let previousUpload = defaults.object(forKey: IDeviceUploadSettings.lastUploadKey)
        defer {
            defaults.set(previousChunkSize, forKey: IDeviceUploadSettings.chunkSizeKey)
            defaults.set(previousUpload, forKey: IDeviceUploadSettings.lastUploadKey)
        }
        defaults.removeObject(forKey: IDeviceUploadSettings.chunkSizeKey)
        precondition(IDeviceUploadSettings.chunkSizeMB() == 1)
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
        // An in-flight upload keeps its snapshot even if Settings changes.
        defaults.set(16, forKey: IDeviceUploadSettings.chunkSizeKey)
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
                     "Changing Settings must not change the size of active uploads")
        defaults.set(1, forKey: IDeviceUploadSettings.chunkSizeKey)

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
        let megabyte = 1024 * 1024
        for savedSize in [1, 2, 4, 8, 16, 0, 3, 128] {
            defaults.set(savedSize, forKey: IDeviceUploadSettings.chunkSizeKey)
            let size = IDeviceUploadSettings.chunkSizesMB.contains(savedSize) ? savedSize : 1
            let chunkBytes = size * megabyte
            let byteCount = chunkBytes * 2 + 123
            try Data(repeating: 42, count: byteCount).write(to: ipa)
            let model = InstallerStatusViewModel()
            try await InstallationProxy(viewModel: model).install(at: ipa)
            precondition(NativeCalls.shared.takeWriteCounts() == [chunkBytes, chunkBytes, 123],
                         "Selected size must reach the native API, including the final partial chunk")
            await MainActor.run {
                guard let metrics = model.uploadMetrics else {
                    preconditionFailure("Completed upload must report metrics")
                }
                precondition(metrics.bytes == UInt64(byteCount) && metrics.chunkSizeMB == size)
                precondition(metrics.duration > 0 && metrics.averageMBPerSecond.isFinite)
                let persisted = try! JSONDecoder().decode(IDeviceUploadMetrics.self,
                    from: defaults.data(forKey: IDeviceUploadSettings.lastUploadKey)!)
                precondition(persisted.bytes == metrics.bytes && persisted.chunkSizeMB == size)
            }
        }
        NativeCalls.shared.expectCleanClients(30, tunnelCount: 2)
        NativeCalls.shared.expectFreed(1)
        await HeartbeatManager.shared.resetInstallationConnection()
        NativeCalls.shared.expectFreed(2)
        HeartbeatManager.configurePairingPath(nil)
        print("Passed shared native tunnel, overlapping uploads, chunk sizes, upload metrics, installer error classification and lease cleanup")
    }
}

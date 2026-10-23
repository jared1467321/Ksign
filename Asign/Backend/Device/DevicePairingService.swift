import BackgroundTasks
import Combine
import Foundation
import IDevice
import UIKit

// Native callbacks only hold this context until the blocking run returns.
private final class PairingOperation: @unchecked Sendable {
    let handle: OpaquePointer
    let event: (Int32, String) -> Void
    init(event: @escaping (Int32, String) -> Void) throws {
        guard let handle = ksign_pairing_new() else { throw DeviceSetupError("Cannot start pairing.") }
        self.handle = handle
        self.event = event
    }
    func cancel() { ksign_pairing_cancel(handle) }
    deinit { ksign_pairing_free(handle) }

    func run() throws -> DevicePairingRecord {
        var output: UnsafeMutablePointer<CChar>?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let error = ksign_pairing_run(handle, "Asign", { context, event, payload in
            guard let context, let payload else { return }
            Unmanaged<PairingOperation>.fromOpaque(context).takeUnretainedValue()
                .event(event, String(cString: payload))
        }, context, &output)
        defer { ksign_pairing_string_free(output) }
        if let error {
            defer { idevice_error_free(error) }
            let message = error.pointee.message.map { String(cString: $0) } ?? "Pairing failed."
            throw DeviceSetupError(message)
        }
        guard let output else { throw DeviceSetupError("Pairing returned no credentials.") }
        let record = try JSONDecoder().decode(DevicePairingRecord.self, from: Data(String(cString: output).utf8))
        try record.validate()
        return record
    }
}

@MainActor
final class DevicePairingService: NSObject, ObservableObject, NetServiceDelegate {
    static let shared = DevicePairingService()
    @Published private(set) var pin: String?
    @Published private(set) var isRunning = false
    private var operation: PairingOperation?
    private var service: NetService?
    private var runID: UUID?
    private var advertisementError: Error?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var continuedTask: AnyObject?
    private static var taskID: String { (Bundle.main.bundleIdentifier ?? "Ksign") + ".userTask.pairing" }

    static func registerBackgroundTask() {
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: .main) { task in
                guard let task = task as? BGContinuedProcessingTask else { return }
                Task { @MainActor in Self.shared.acceptBackgroundTask(task) }
            }
        }
    }

    func pair() async throws -> DevicePairingRecord {
        guard #available(iOS 27.0, *) else {
            throw DeviceSetupError("Creating a pairing on this device requires iOS 27 or later. You can still import an existing pairing in Manual Setup.")
        }
        guard !isRunning else { throw DeviceSetupError("Pairing is already in progress.") }
        let id = UUID()
        let operation = try PairingOperation { [weak self] event, text in
            Task { @MainActor in
                guard let self, self.runID == id else { return }
                self.handle(event: event, text: text)
            }
        }
        self.operation = operation
        runID = id
        isRunning = true
        pin = nil
        advertisementError = nil
        beginBackgroundTime()
        var succeeded = false
        defer {
            service?.stop()
            service = nil
            runID = nil
            self.operation = nil
            isRunning = false
            pin = nil
            endBackgroundTime(success: succeeded)
        }
        do {
            let record = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DevicePairingRecord, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do { continuation.resume(returning: try operation.run()) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
            } onCancel: { operation.cancel() }
            try Task.checkCancellation()
            if let advertisementError { throw advertisementError }
            succeeded = true
            return record
        } catch {
            if let advertisementError { throw advertisementError }
            throw error
        }
    }

    func cancel() { operation?.cancel() }

    private func handle(event: Int32, text: String) {
        if event == 0 {
            struct Advertisement: Decodable { let identifier: String; let port: UInt16; let txt: [String: String] }
            do {
                let ad = try JSONDecoder().decode(Advertisement.self, from: Data(text.utf8))
                let service = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.",
                                         name: ad.identifier, port: Int32(ad.port))
                service.delegate = self
                service.setTXTRecord(NetService.data(fromTXTRecord: ad.txt.mapValues { Data($0.utf8) }))
                self.service = service
                service.publish()
            } catch { advertisementError = error; cancel() }
        } else if event == 1 {
            pin = text
            if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
                task.progress.completedUnitCount = 1
                task.updateTitle("Pair with Asign", subtitle: "Enter code \(text) in Settings")
            }
        }
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        advertisementError = DeviceSetupError("Asign could not advertise for pairing. Allow Local Network access in Settings, connect to Wi-Fi, and try again.")
        cancel()
    }

    private func beginBackgroundTime() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Device pairing") { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
        if #available(iOS 26.0, *) {
            let request = BGContinuedProcessingTaskRequest(identifier: Self.taskID,
                title: "Pair with Asign", subtitle: "Open Developer Mode in Settings")
            request.strategy = .fail
            try? BGTaskScheduler.shared.submit(request)
        }
    }

    @available(iOS 26.0, *)
    private func acceptBackgroundTask(_ task: BGContinuedProcessingTask) {
        guard isRunning else { task.setTaskCompleted(success: false); return }
        continuedTask = task
        task.progress.totalUnitCount = 2
        task.progress.completedUnitCount = pin == nil ? 0 : 1
        task.expirationHandler = { [weak self] in Task { @MainActor in self?.cancel() } }
        if let pin { task.updateTitle("Pair with Asign", subtitle: "Enter code \(pin) in Settings") }
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func endBackgroundTime(success: Bool) {
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
            if let task = continuedTask as? BGContinuedProcessingTask {
                if success { task.progress.completedUnitCount = 2 }
                task.setTaskCompleted(success: success)
            }
        }
        continuedTask = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}

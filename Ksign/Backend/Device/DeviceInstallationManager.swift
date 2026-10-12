import Combine
import Foundation
import IDeviceSwift
import UIKit

enum DeviceConnectionMode: String, CaseIterable, Identifiable {
    case builtIn, manual
    var id: String { rawValue }
    var title: String { self == .builtIn ? "Built-in Connection" : "Manual Setup" }
}

@MainActor
final class DeviceInstallationManager: ObservableObject {
    static let shared = DeviceInstallationManager()
    enum Phase: Equatable { case idle, connecting, pairing, ready, disconnecting, configured, failed(String), cleanupFailed(String) }
    @Published private(set) var phase: Phase = .idle
    @Published var mode: DeviceConnectionMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "Ksign.deviceConnectionMode") }
    }
    @Published private(set) var pendingOperations = 0
    private let vpn = LocalDeviceVPN()
    private var configuredMode: DeviceConnectionMode?
    private var setupFailure: Error?
    private var tail: Task<Void, Never>?
    private var activeOperation: Task<Void, Error>?
    private var operations: [UUID: Task<Void, Error>] = [:]
    private var workflows: Set<UUID> = []
    private var cleanupTask: Task<Void, Never>?

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "Ksign.deviceConnectionMode"),
           let saved = DeviceConnectionMode(rawValue: raw) { mode = saved }
        else if #available(iOS 27.0, *), LocalDeviceVPN.extensionBundleIdentifier != nil,
                !FileManager.default.fileExists(atPath: Self.legacyPairingPath) { mode = .builtIn }
        else { mode = .manual }
        DevicePairingStore.removeWorkingCopy()
    }

    static var legacyPairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    var isBusy: Bool { pendingOperations > 0 || cleanupTask != nil }
    var showsSetup: Bool {
        switch phase { case .connecting, .pairing, .disconnecting, .failed, .cleanupFailed: return true; default: return false }
    }

    func retainWorkflow(_ id: UUID) { workflows.insert(id) }
    func releaseWorkflow(_ id: UUID) { workflows.remove(id); cleanUpIfIdle() }
    func clearSetupFailure() { setupFailure = nil; if case .failed = phase { phase = .idle } }

    func setUp() async {
        guard !isBusy else { return }
        clearSetupFailure()
        let selectedMode = mode
        do { try await enqueue { try await self.prepare(selectedMode) } }
        catch { phase = .failed(error.localizedDescription) }
    }

    func cancelSetup() { activeOperation?.cancel(); DevicePairingService.shared.cancel() }

    func resetPairing() async {
        guard !isBusy, workflows.isEmpty else { return }
        if let cleanupTask { await cleanupTask.value }
        await HeartbeatManager.shared.resetInstallationConnection()
        HeartbeatManager.configurePairingPath(nil)
        configuredMode = nil
        do {
            try await vpn.disconnectIfOwned()
            try DevicePairingStore.reset()
            clearSetupFailure()
            phase = .idle
        }
        catch { phase = .failed(error.localizedDescription) }
    }

    func retryDisconnect() {
        guard pendingOperations == 0, workflows.isEmpty else { return }
        cleanUpIfIdle()
    }

    func install(at url: URL, viewModel: InstallerStatusViewModel, suspend: Bool,
                 mode: DeviceConnectionMode, isCurrent: @escaping () -> Bool = { true }) async throws {
        try await enqueue {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            try await self.prepare(mode)
            try Task.checkCancellation()
            do {
                let proxy = InstallationProxy(viewModel: viewModel)
                try await proxy.install(at: url, suspend: suspend, isCurrent: isCurrent)
            } catch {
                // The next app can reconnect, but never automatically reinstall
                // an IPA whose commit may already have reached the device.
                await HeartbeatManager.shared.resetInstallationConnection()
                self.configuredMode = nil
                throw error
            }
        }
    }

    private func enqueue(_ body: @escaping () async throws -> Void) async throws {
        pendingOperations += 1
        let id = UUID()
        let previous = tail
        let operation = Task { @MainActor in
            if let previous { await previous.value }
            try Task.checkCancellation()
            if let cleanupTask = self.cleanupTask { await cleanupTask.value }
            try Task.checkCancellation()
            self.activeOperation = self.operations[id]
            try await body()
        }
        operations[id] = operation
        let completion = Task { _ = await operation.result }
        tail = completion
        // Cancellation is forwarded, but we await real native completion before
        // advancing the queue. Dismissing a row cannot overlap two native writes.
        defer {
            operations[id] = nil
            pendingOperations -= 1
            if pendingOperations == 0 { tail = nil; activeOperation = nil }
            cleanUpIfIdle()
        }
        // Setup is only started by the head of the queue.
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: { operation.cancel() }
    }

    private func prepare(_ mode: DeviceConnectionMode) async throws {
        if let setupFailure { throw setupFailure }
        if configuredMode == mode, mode == .manual || vpn.isConnected { return }
        phase = .connecting
        do {
            await HeartbeatManager.shared.resetInstallationConnection()
            if mode == .builtIn {
                // Check VPN provisioning before asking the user to perform pairing.
                try await vpn.connect()
                var record = try DevicePairingStore.load()
                if record == nil, !FileManager.default.fileExists(atPath: Self.legacyPairingPath) {
                    phase = .pairing
                    let paired = try await DevicePairingService.shared.pair()
                    try Task.checkCancellation()
                    try DevicePairingStore.save(paired)
                    record = paired
                }
                if let record {
                    HeartbeatManager.configurePairingPath(try DevicePairingStore.materialize(record).path)
                } else {
                    HeartbeatManager.configurePairingPath(nil)
                }
            } else {
                try await vpn.disconnectIfOwned()
                HeartbeatManager.configurePairingPath(nil)
                guard FileManager.default.fileExists(atPath: Self.legacyPairingPath) else {
                    throw DeviceSetupError("Import a pairing file and connect your local VPN in Manual Setup, or choose Built-in Connection on a supported device.")
                }
            }
            try Task.checkCancellation()
            phase = .connecting
            try await HeartbeatManager.shared.prepareInstallationConnection()
            try Task.checkCancellation()
            configuredMode = mode
            phase = .ready
        } catch {
            configuredMode = nil
            let failure = error is CancellationError ? DeviceSetupError("Device setup was cancelled. Tap Retry Setup when you are ready.") : error
            setupFailure = failure
            phase = .failed(failure.localizedDescription)
            throw failure
        }
    }

    private func cleanUpIfIdle() {
        guard pendingOperations == 0, workflows.isEmpty, cleanupTask == nil else { return }
        cleanupTask = Task { @MainActor in
            let previousPhase = self.phase
            if self.vpn.needsDisconnection { self.phase = .disconnecting }
            // Give the asynchronous stop/preferences save time to complete if
            // the user leaves Ksign immediately after the last app installs.
            let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Disconnect installation VPN")
            defer {
                if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
                self.cleanupTask = nil
            }
            await HeartbeatManager.shared.resetInstallationConnection()
            self.configuredMode = nil
            HeartbeatManager.configurePairingPath(nil)
            DevicePairingStore.removeWorkingCopy()
            do {
                try await self.vpn.disconnectIfOwned()
                switch previousPhase {
                case .ready, .configured, .cleanupFailed, .disconnecting: self.phase = .configured
                default: self.phase = previousPhase
                }
            } catch {
                self.phase = .cleanupFailed("Ksign could not fully disable its installation VPN. Tap Disconnect VPN to retry, or stop it in iOS VPN Settings.\n\n\(error.localizedDescription)")
            }
        }
    }
}

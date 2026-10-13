import Combine
import Foundation
import IDeviceSwift

enum DeviceConnectionMode: String, CaseIterable, Identifiable {
    case builtIn, manual
    var id: String { rawValue }
    var title: String { self == .builtIn ? "Built-in Connection" : "Manual Setup" }
}

@MainActor
final class DeviceInstallationManager: ObservableObject {
    static let shared = DeviceInstallationManager()
    enum Phase: Equatable { case idle, connecting, pairing, ready, configured, failed(String) }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var setupNotice: String?
    @Published var mode: DeviceConnectionMode {
        didSet { defaults.set(mode.rawValue, forKey: "Ksign.deviceConnectionMode") }
    }
    @Published private(set) var pendingOperations = 0
    private let vpn: LocalDeviceVPN
    private let defaults: UserDefaults
    private let legacyPairingExists: @MainActor () -> Bool
    private let canCreatePairing: @MainActor () -> Bool
    private static let freshPairingKey = "Ksign.needsFreshBuiltInPairing"
    private var configuredMode: DeviceConnectionMode?
    private var setupFailure: Error?
    private var tail: Task<Void, Never>?
    private var activeOperation: Task<Void, Error>?
    private var operations: [UUID: Task<Void, Error>] = [:]
    private var workflows: Set<UUID> = []
    private var cleanupTask: Task<Void, Never>?
    private var activeInstallations: Set<UUID> = []
    private var installingBundles: [String: UUID] = [:]
    private var exclusiveInstallation: UUID?
    private var needsConnectionRecovery = false

    init(vpn: LocalDeviceVPN? = nil, defaults: UserDefaults = .standard,
         legacyPairingExists: @escaping @MainActor () -> Bool = {
             FileManager.default.fileExists(atPath: DeviceInstallationManager.legacyPairingPath)
         },
         canCreatePairing: @escaping @MainActor () -> Bool = {
             if #available(iOS 27.0, *) { return true }
             return false
         }) {
        self.vpn = vpn ?? LocalDeviceVPN()
        self.defaults = defaults
        self.legacyPairingExists = legacyPairingExists
        self.canCreatePairing = canCreatePairing
        if let raw = defaults.string(forKey: "Ksign.deviceConnectionMode"),
           let saved = DeviceConnectionMode(rawValue: raw) { mode = saved }
        else if canCreatePairing(), LocalDeviceVPN.extensionBundleIdentifier != nil,
                !legacyPairingExists() { mode = .builtIn }
        else { mode = .manual }
        DevicePairingStore.removeWorkingCopy()
    }

    static var legacyPairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    var isBusy: Bool { pendingOperations > 0 }
    var showsSetup: Bool {
        switch phase { case .connecting, .pairing, .failed: return true; default: return false }
    }

    func retainWorkflow(_ id: UUID) { workflows.insert(id) }
    func releaseWorkflow(_ id: UUID) { workflows.remove(id); cleanUpIfIdle() }
    func clearSetupFailure() {
        setupFailure = nil
        setupNotice = nil
        if case .failed = phase { phase = .idle }
    }

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
        vpn.disconnectIfOwned()
        configuredMode = nil
        do {
            try DevicePairingStore.reset()
            // Do not silently reuse an imported pairing after the user asks to
            // pair again. Keep that file intact for Manual Setup.
            defaults.set(canCreatePairing(), forKey: Self.freshPairingKey)
            clearSetupFailure()
            phase = .idle
        }
        catch { phase = .failed(error.localizedDescription) }
    }

    func install(at url: URL, viewModel: InstallerStatusViewModel, suspend: Bool,
                 mode: DeviceConnectionMode, bundleIdentifier: String? = nil,
                 isCurrent: @escaping () -> Bool = { true }) async throws {
        let id = UUID()
        pendingOperations += 1
        defer {
            activeInstallations.remove(id)
            if let bundleIdentifier, installingBundles[bundleIdentifier] == id {
                installingBundles[bundleIdentifier] = nil
            }
            if exclusiveInstallation == id { exclusiveInstallation = nil }
            pendingOperations -= 1
            cleanUpIfIdle()
        }
        // Serialize preparation and reservation only. Once admitted, each proxy
        // owns its connection and can upload/install alongside the other jobs.
        try await enqueue(countsOperation: false) {
            while self.exclusiveInstallation != nil ||
                bundleIdentifier.map({ self.installingBundles[$0] != nil }) == true ||
                (!self.activeInstallations.isEmpty &&
                (suspend || self.needsConnectionRecovery || self.configuredMode != mode ||
                 (mode == .builtIn && !self.vpn.isConnected))) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            if self.needsConnectionRecovery {
                self.configuredMode = nil
                self.needsConnectionRecovery = false
            }
            try await self.prepare(mode)
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            self.activeInstallations.insert(id)
            if let bundleIdentifier { self.installingBundles[bundleIdentifier] = id }
            if suspend { self.exclusiveInstallation = id }
        }
        do {
            try Task.checkCancellation()
            let proxy = InstallationProxy(viewModel: viewModel)
            try await proxy.install(at: url, suspend: suspend, isCurrent: isCurrent)
        } catch {
            // A failed attempt must not reset the VPN beneath other installs.
            // The next preparation recovers only after all active leases drain;
            // never replay an IPA whose commit may already have reached iOS.
            if !(error is CancellationError) {
                needsConnectionRecovery = true
            }
            throw error
        }
    }

    private func enqueue(countsOperation: Bool = true, _ body: @escaping () async throws -> Void) async throws {
        if countsOperation { pendingOperations += 1 }
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
        // Preparation is shared by the admitted installs. Cancelling one waiter
        // must not cancel another waiter's preparation or release its lease.
        defer {
            operations[id] = nil
            if countsOperation { pendingOperations -= 1 }
            if operations.isEmpty { tail = nil; activeOperation = nil }
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
            try Task.checkCancellation()
            if mode == .builtIn {
                try await prepareBuiltInConnection()
            } else {
                vpn.disconnectIfOwned()
                HeartbeatManager.configurePairingPath(nil)
                guard legacyPairingExists() else {
                    throw DeviceSetupError("Import a pairing file and connect your local VPN in Manual Setup, or choose Built-in Connection on a supported device.")
                }
                try await HeartbeatManager.shared.prepareInstallationConnection()
            }
            try Task.checkCancellation()
            configuredMode = mode
            setupNotice = nil
            phase = .ready
        } catch {
            configuredMode = nil
            setupNotice = nil
            let failure = error is CancellationError ? DeviceSetupError("Device setup was cancelled. Tap Retry Setup when you are ready.") : error
            setupFailure = failure
            phase = .failed(failure.localizedDescription)
            throw failure
        }
    }

    private func prepareBuiltInConnection() async throws {
        let needsFreshPairing = defaults.bool(forKey: Self.freshPairingKey)
        // Validate VPN provisioning before asking for pairing consent.
        try await vpn.connect(restarting: needsFreshPairing)
        try Task.checkCancellation()
        var record = try DevicePairingStore.load()
        let usesLegacyPairing = record == nil && legacyPairingExists() && !needsFreshPairing
        let reusedPairing = record != nil || usesLegacyPairing
        if record == nil && !usesLegacyPairing { record = try await createPairing() }
        try configurePairing(record)
        phase = .connecting
        do {
            try await HeartbeatManager.shared.prepareInstallationConnection()
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            // Retry the handshake, never an installation that may have committed.
            setupNotice = "Restarting the local VPN to recover the device connection…"
            await HeartbeatManager.shared.resetInstallationConnection()
            try Task.checkCancellation()
            try await vpn.connect(restarting: true)
            try Task.checkCancellation()
            do {
                try await HeartbeatManager.shared.prepareInstallationConnection()
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                guard reusedPairing else { throw error }
                guard canCreatePairing() else {
                    throw DeviceSetupError("The saved pairing could not connect after restarting the local VPN. Import a fresh pairing file in Manual Setup and retry.\n\n\(error.localizedDescription)")
                }
                setupNotice = "The saved pairing could not reconnect. Pair with Ksign again in Settings to repair the connection."
                await HeartbeatManager.shared.resetInstallationConnection()
                try Task.checkCancellation()
                // Keep the previous credentials until replacement pairing succeeds.
                record = try await createPairing()
                try configurePairing(record)
                phase = .connecting
                try await HeartbeatManager.shared.prepareInstallationConnection()
            }
        }
    }

    private func createPairing() async throws -> DevicePairingRecord {
        try Task.checkCancellation()
        phase = .pairing
        let record = try await DevicePairingService.shared.pair()
        try Task.checkCancellation()
        try DevicePairingStore.save(record)
        defaults.set(false, forKey: Self.freshPairingKey)
        return record
    }

    private func configurePairing(_ record: DevicePairingRecord?) throws {
        if let record {
            HeartbeatManager.configurePairingPath(try DevicePairingStore.materialize(record).path)
        } else {
            HeartbeatManager.configurePairingPath(nil)
        }
    }

    private func cleanUpIfIdle() {
        guard pendingOperations == 0, workflows.isEmpty, cleanupTask == nil else { return }
        cleanupTask = Task { @MainActor in
            await HeartbeatManager.shared.resetInstallationConnection()
            self.configuredMode = nil
            self.needsConnectionRecovery = false
            HeartbeatManager.configurePairingPath(nil)
            DevicePairingStore.removeWorkingCopy()
            self.vpn.disconnectIfOwned()
            if case .ready = self.phase { self.phase = .configured }
            self.cleanupTask = nil
        }
    }
}

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
    private(set) var pendingOperations = 0 {
        didSet { updateAvailability() }
    }
    private let vpn: LocalDeviceVPN
    private let vpnReconnect: VPNReconnectCoordinator
    private let defaults: UserDefaults
    private let legacyPairingExists: @MainActor () -> Bool
    private let canCreatePairing: @MainActor () -> Bool
    private static let freshPairingKey = "Ksign.needsFreshBuiltInPairing"
    private var configuredMode: DeviceConnectionMode?
    private var setupFailure: Error?
    private var tail: Task<Void, Never>?
    private var activeOperation: Task<Void, Error>?
    private var operations: [UUID: Task<Void, Error>] = [:]
    private var workflows: Set<UUID> = [] {
        didSet { updateAvailability() }
    }
    private var cleanupTask: Task<Void, Never>? {
        didSet { updateAvailability() }
    }
    private struct Availability: Equatable {
        var isBusy = false
        var canReconnectVPN = true
    }
    @Published private var availability = Availability()
    private var activeInstallations: Set<UUID> = []
    private var installingBundles: [String: UUID] = [:]
    private var exclusiveInstallation: UUID?
    private var needsConnectionRecovery = false

    init(vpn: LocalDeviceVPN? = nil, defaults: UserDefaults = .standard,
         vpnReconnect: VPNReconnectCoordinator? = nil,
         legacyPairingExists: @escaping @MainActor () -> Bool = {
             FileManager.default.fileExists(atPath: DeviceInstallationManager.legacyPairingPath)
         },
         canCreatePairing: @escaping @MainActor () -> Bool = {
             if #available(iOS 27.0, *) { return true }
             return false
         }) {
        self.vpn = vpn ?? LocalDeviceVPN()
        self.vpnReconnect = vpnReconnect ?? .shared
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

    var isBusy: Bool { availability.isBusy }
    var showsSetup: Bool {
        switch phase { case .connecting, .pairing, .failed: return true; default: return false }
    }

    func retainWorkflow(_ id: UUID, requiresVPNChoice: Bool = false) {
        vpnReconnect.beginDeviceWork(requiresUserChoice: requiresVPNChoice)
        workflows.insert(id)
    }
    func releaseWorkflow(_ id: UUID) { workflows.remove(id); cleanUpIfIdle() }
    var canReconnectVPN: Bool { availability.canReconnectVPN }

    private func updateAvailability() {
        let next = Availability(isBusy: pendingOperations > 0,
                                canReconnectVPN: pendingOperations == 0 && workflows.isEmpty && cleanupTask == nil)
        if next != availability { availability = next }
    }

    func testVPNReconnectShortcut() async {
        guard canReconnectVPN else { return }
        await vpnReconnect.testShortcut()
    }
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

    /// Serialize read-only preflight with connection preparation. Active native
    /// installs retain their tunnel; queries never reset it beneath those leases.
    func validate(_ preflight: IDeviceInstallPreflight) async throws {
        let selectedMode = mode
        try await enqueue {
            while self.exclusiveInstallation != nil ||
                (!self.activeInstallations.isEmpty &&
                 (self.needsConnectionRecovery || self.configuredMode != selectedMode)) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if self.needsConnectionRecovery {
                self.configuredMode = nil
                self.needsConnectionRecovery = false
            }
            try Task.checkCancellation()
            try await self.prepare(selectedMode)
            do {
                try await InstallationProxy(viewModel: InstallerStatusViewModel()).validate(preflight)
            } catch {
                if !(error is CancellationError), !(error is IDeviceInstallSkip),
                   !(error is IDeviceInstallationRejection) { self.needsConnectionRecovery = true }
                throw error
            }
        }
    }

    func installedApps() async throws -> [IDeviceInstalledApp] {
        let selectedMode = mode
        var apps: [IDeviceInstalledApp] = []
        try await enqueue(requiresVPNChoice: true) {
            while self.exclusiveInstallation != nil ||
                (!self.activeInstallations.isEmpty &&
                 (self.needsConnectionRecovery || self.configuredMode != selectedMode)) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try Task.checkCancellation()
            if self.needsConnectionRecovery {
                self.configuredMode = nil
                self.needsConnectionRecovery = false
            }
            try await self.prepare(selectedMode)
            do {
                apps = try await InstallationProxy(viewModel: InstallerStatusViewModel()).installedApps()
            } catch {
                if !(error is CancellationError), !(error is IDeviceInstallationRejection) {
                    self.needsConnectionRecovery = true
                }
                throw error
            }
        }
        return apps
    }

    /// Hold the preparation queue until removal completes. Previously admitted
    /// installs drain first; no new install can reserve the connection meanwhile.
    func uninstall(_ request: IDeviceUninstallRequest) async throws -> Bool {
        guard request.bundleIdentifier != Bundle.main.bundleIdentifier else {
            throw IDeviceInstallSkip(reason: "Asign cannot uninstall itself.")
        }
        try UninstallBlacklist.shared.checkRemovalAllowed(for: request.bundleIdentifier)
        let selectedMode = mode
        var removed = false
        try await enqueue {
            while !self.activeInstallations.isEmpty {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try Task.checkCancellation()
            if self.needsConnectionRecovery {
                self.configuredMode = nil
                self.needsConnectionRecovery = false
            }
            try await self.prepare(selectedMode)
            do {
                try UninstallBlacklist.shared.checkRemovalAllowed(for: request.bundleIdentifier)
                removed = try await InstallationProxy(viewModel: InstallerStatusViewModel()).uninstall(request)
            } catch {
                if !(error is CancellationError), !(error is IDeviceInstallSkip),
                   !(error is IDeviceInstallationRejection) { self.needsConnectionRecovery = true }
                // Never replay an uninstall after an ambiguous transport error.
                throw error
            }
        }
        return removed
    }

    func resetPairing() async {
        guard !isBusy, workflows.isEmpty else { return }
        if let cleanupTask { await cleanupTask.value }
        vpnReconnect.beginDeviceWork()
        defer { cleanUpIfIdle() }
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
                 preflight: IDeviceInstallPreflight? = nil,
                 isCurrent: @escaping () -> Bool = { true }) async throws {
        let id = UUID()
        vpnReconnect.beginDeviceWork()
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
        // leases the shared tunnel and owns clients that can upload/install
        // alongside the other jobs.
        try await enqueue(countsOperation: false) {
            while self.exclusiveInstallation != nil ||
                bundleIdentifier.map({ self.installingBundles[$0] != nil }) == true ||
                (!self.activeInstallations.isEmpty &&
                (suspend || self.needsConnectionRecovery || self.configuredMode != mode)) {
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
            try await proxy.install(at: url, suspend: suspend, preflight: preflight, isCurrent: isCurrent)
        } catch {
            // A rejected app does not invalidate a working device connection.
            // Other failed attempts must not reset the VPN beneath peers.
            // The next preparation recovers only after all active leases drain;
            // never replay an IPA whose commit may already have reached iOS.
            if !(error is CancellationError), !(error is IDeviceInstallationRejection), !(error is IDeviceInstallSkip) {
                needsConnectionRecovery = true
            }
            throw error
        }
    }

    private func enqueue(countsOperation: Bool = true, requiresVPNChoice: Bool = false,
                         _ body: @escaping () async throws -> Void) async throws {
        if countsOperation {
            vpnReconnect.beginDeviceWork(requiresUserChoice: requiresVPNChoice)
            pendingOperations += 1
        }
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
        // VPN status can change when cellular returns even while established
        // native streams keep working. Preserve that session for later apps,
        // just as Manual Setup does. An actual install error requests recovery
        // after active leases drain; status alone must not discard the tunnel.
        if configuredMode == mode { return }
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
                setupNotice = "The saved pairing could not reconnect. Pair with Asign again in Settings to repair the connection."
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
            let restoreVPN = await self.vpn.finishSession()
            if case .ready = self.phase { self.phase = .configured }
            // New work waits for cleanup but can arrive while the tunnel is
            // stopping. Never reconnect another VPN underneath that work.
            if self.pendingOperations == 0, self.workflows.isEmpty {
                await self.vpnReconnect.deviceWorkFinished(restoreVPN: restoreVPN && self.mode == .builtIn)
            }
            self.cleanupTask = nil
        }
    }
}

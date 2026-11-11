import Foundation

/// Proof of a completed Asign install, tied to that installed copy rather than
/// just its bundle ID. Never infer ownership from a saved IPA or library row.
public struct IDeviceManagedInstall: Codable, Equatable, Sendable {
    public let token: UUID
    public let bundleIdentifier: String
    public let applicationIdentifier: String
    public let installationPath: String?
    public let registrationDate: Date?
    public let installedAt: Date

    public func matches(_ app: IDeviceInstalledApp) -> Bool {
        guard app.bundleIdentifier == bundleIdentifier,
              app.applicationIdentifier == applicationIdentifier else { return false }
        if let installationPath { return app.installationPath == installationPath }
        guard let registrationDate else { return false }
        return app.registrationDate == registrationDate
    }

    /// Missing metadata hides the app without destroying a valid receipt.
    /// Only affirmative evidence of a replacement invalidates ownership.
    func wasReplaced(by app: IDeviceInstalledApp) -> Bool {
        if let identity = app.applicationIdentifier, identity != applicationIdentifier { return true }
        if let installationPath, let currentPath = app.installationPath {
            return currentPath != installationPath
        }
        if installationPath == nil, let registrationDate, let currentDate = app.registrationDate {
            return currentDate != registrationDate
        }
        return false
    }
}

/// Evidence that Asign served a particular signed IPA. This becomes an
/// uninstall receipt only after the device reports a matching new copy.
public struct IDeviceServerInstallObservation: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let applicationIdentifier: String
    public let version: String?
    public let startedAt: Date
    private let previousRegistrationDate: Date?
    private let previousPath: String?
    private let wasAbsent: Bool

    public init(bundleIdentifier: String, applicationIdentifier: String, version: String?,
                startedAt: Date, previousRegistrationDate: Date?, previousPath: String?, wasAbsent: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationIdentifier = applicationIdentifier
        self.version = version
        self.startedAt = startedAt
        self.previousRegistrationDate = previousRegistrationDate
        self.previousPath = previousPath
        self.wasAbsent = wasAbsent
    }

    public func sawNewCopy(path: String?, registrationDate: Date?, servedAt: Date, now: Date = Date()) -> Bool {
        let deadline = servedAt.addingTimeInterval(3600)
        if let registrationDate, registrationDate > deadline { return false }
        if let registrationDate, registrationDate >= startedAt,
           previousRegistrationDate.map({ registrationDate > $0 }) ?? true { return true }

        // Device dates can be unavailable or rounded. In that case a fresh
        // bundle path also identifies a change, but only near the transfer.
        guard now <= deadline, let path, !path.isEmpty else { return false }
        if let registrationDate, registrationDate != previousRegistrationDate,
           registrationDate < startedAt.addingTimeInterval(-1) { return false }
        if let previousPath { return Self.canonical(path) != Self.canonical(previousPath) }
        return wasAbsent
    }

    private static func canonical(_ path: String) -> String {
        path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }
}

/// One atomic file outside the library. Workers share this lock so concurrent
/// installs cannot overwrite each other's receipts. Read/write failures fail
/// closed; a failed save never grants permission to uninstall an app.
public final class IDeviceManagedInstallRegistry: @unchecked Sendable {
    public static let shared = IDeviceManagedInstallRegistry(fileURL:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Ksign/ManagedInstalls.json"))

    private struct FileContents: Codable {
        let version: Int
        let records: [IDeviceManagedInstall]
        let serverTransfers: [ServerTransfer]?
    }
    private struct ServerTransfer: Codable, Equatable {
        let observation: IDeviceServerInstallObservation
        let servedAt: Date
    }
    private let fileURL: URL
    private let lock = NSLock()
    private var records: [IDeviceManagedInstall] = []
    private var serverTransfers: [ServerTransfer] = []
    private var readFailure: String?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        do {
            let data = try Data(contentsOf: fileURL)
            let contents = try JSONDecoder().decode(FileContents.self, from: data)
            guard contents.version == 1,
                  Set(contents.records.map(\.bundleIdentifier)).count == contents.records.count,
                  contents.records.allSatisfy({
                      !$0.bundleIdentifier.isEmpty && !$0.applicationIdentifier.isEmpty &&
                          ($0.installationPath?.isEmpty == false || $0.registrationDate != nil)
                  }) else {
                throw IDeviceInstallSkip(reason: "Unsupported or invalid install tracking file.")
            }
            records = contents.records
            serverTransfers = contents.serverTransfers ?? []
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A fresh installation has no owned apps yet.
        } catch {
            readFailure = "Asign couldn't read its installed-app records: \(error.localizedDescription)"
        }
    }

    public func snapshot() throws -> [IDeviceManagedInstall] {
        lock.lock()
        defer { lock.unlock() }
        try checkReadable()
        return records
    }

    /// Call only after installation_proxy has confirmed a successful install.
    public func recordConfirmedInstall(_ app: IDeviceInstalledApp,
                                       hostBundleIdentifier: String? = Bundle.main.bundleIdentifier) throws {
        guard app.removalRestriction(hostBundleIdentifier: hostBundleIdentifier) == nil,
              let identity = app.applicationIdentifier, !identity.isEmpty,
              app.installationPath?.isEmpty == false || app.registrationDate != nil else { return }
        try store(IDeviceManagedInstall(token: UUID(), bundleIdentifier: app.id,
            applicationIdentifier: identity, installationPath: app.installationPath.flatMap { $0.isEmpty ? nil : $0 },
            registrationDate: app.registrationDate, installedAt: Date()))
    }

    public func recordServerTransfer(_ observation: IDeviceServerInstallObservation, servedAt: Date,
                                     hostBundleIdentifier: String? = Bundle.main.bundleIdentifier) throws {
        guard observation.bundleIdentifier != hostBundleIdentifier, !observation.bundleIdentifier.isEmpty,
              !observation.applicationIdentifier.isEmpty, observation.startedAt <= servedAt else { return }
        lock.lock()
        defer { lock.unlock() }
        try checkReadable()
        guard !records.contains(where: {
            $0.bundleIdentifier == observation.bundleIdentifier && $0.installedAt >= observation.startedAt
        }), !serverTransfers.contains(where: {
            $0.observation.bundleIdentifier == observation.bundleIdentifier &&
                $0.observation.startedAt >= observation.startedAt
        }) else { return }
        let pending = serverTransfers.filter {
            $0.observation.bundleIdentifier != observation.bundleIdentifier && !Self.isStale($0, at: servedAt)
        } + [ServerTransfer(observation: observation, servedAt: servedAt)]
        try save(records, serverTransfers: pending)
    }

    public func remove(_ record: IDeviceManagedInstall) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkReadable()
        guard records.contains(record) else { return }
        try save(records.filter { $0 != record })
    }

    /// Only prune receipts that existed before this successful device query.
    /// A later concurrent installation must survive an older inventory reply.
    public func reconcile(_ apps: [IDeviceInstalledApp], observed: [IDeviceManagedInstall],
                          hostBundleIdentifier: String?, inventoryStartedAt: Date = Date()) throws -> [IDeviceInstalledApp] {
        lock.lock()
        defer { lock.unlock() }
        try checkReadable()
        let current = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        var retained = records.filter { record in
            guard observed.contains(record) else { return true }
            guard let app = current[record.bundleIdentifier] else { return false }
            guard app.id != hostBundleIdentifier, app.applicationType != "System", app.isRemovable != false else { return false }
            return !record.wasReplaced(by: app)
        }
        let pending = serverTransfers.filter { transfer in
            guard transfer.servedAt <= inventoryStartedAt else { return true }
            guard !Self.isStale(transfer, at: inventoryStartedAt) else { return false }
            let observation = transfer.observation
            guard let app = current[observation.bundleIdentifier],
                  app.removalRestriction(hostBundleIdentifier: hostBundleIdentifier) == nil,
                  app.applicationIdentifier == observation.applicationIdentifier,
                  observation.version == nil || app.version == observation.version,
                  observation.sawNewCopy(path: app.installationPath, registrationDate: app.registrationDate,
                      servedAt: transfer.servedAt, now: inventoryStartedAt) else { return true }
            let path = app.installationPath.flatMap { $0.isEmpty ? nil : $0 }
            guard path != nil || app.registrationDate != nil else { return true }
            guard !records.contains(where: {
                $0.bundleIdentifier == app.id && $0.installedAt >= observation.startedAt
            }) else { return false }
            retained.removeAll { $0.bundleIdentifier == app.id }
            retained.append(IDeviceManagedInstall(token: UUID(), bundleIdentifier: app.id,
                applicationIdentifier: observation.applicationIdentifier, installationPath: path,
                registrationDate: app.registrationDate, installedAt: app.registrationDate ?? transfer.servedAt))
            return false
        }
        if retained != records || pending != serverTransfers { try save(retained, serverTransfers: pending) }
        return apps.filter { app in
            app.removalRestriction(hostBundleIdentifier: hostBundleIdentifier) == nil &&
                retained.contains { $0.matches(app) }
        }
    }

    private func store(_ record: IDeviceManagedInstall) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkReadable()
        try save(records.filter { $0.bundleIdentifier != record.bundleIdentifier } + [record],
            serverTransfers: serverTransfers.filter { $0.observation.bundleIdentifier != record.bundleIdentifier })
    }

    private static func isStale(_ transfer: ServerTransfer, at date: Date) -> Bool {
        date.timeIntervalSince(transfer.servedAt) > 7 * 24 * 3600
    }

    private func checkReadable() throws {
        if let readFailure { throw IDeviceInstallSkip(reason: readFailure) }
    }

    private func save(_ updated: [IDeviceManagedInstall], serverTransfers pending: [ServerTransfer]? = nil) throws {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let pending = pending ?? serverTransfers
            let data = try JSONEncoder().encode(FileContents(version: 1, records: updated, serverTransfers: pending))
            try data.write(to: fileURL, options: .atomic)
            records = updated
            serverTransfers = pending
        } catch {
            throw IDeviceInstallSkip(reason: "Asign couldn't save its installed-app records: \(error.localizedDescription)")
        }
    }
}

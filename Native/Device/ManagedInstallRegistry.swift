import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Proof of a completed Asign install, tied to that installed copy rather than
/// just its bundle ID. Never infer ownership from a saved IPA or library row.
public struct IDeviceManagedInstall: Codable, Equatable, Sendable {
    public let token: UUID
    public let bundleIdentifier: String
    public let applicationIdentifier: String
    public let installationPath: String?
    public let registrationDate: Date?
    public let installedAt: Date
    var name: String? = nil
    var version: String? = nil

    public func matches(_ app: IDeviceInstalledApp) -> Bool {
        guard app.bundleIdentifier == bundleIdentifier,
              app.applicationIdentifier == applicationIdentifier else { return false }
        if let path = installationPath, !path.isEmpty {
            return app.installationPath.map(IDeviceServerInstallObservation.canonical) ==
                IDeviceServerInstallObservation.canonical(path)
        }
        guard let registrationDate else { return false }
        return app.registrationDate == registrationDate
    }

    /// Use the saved display details until the device can verify the copy again.
    public var unverifiedApp: IDeviceInstalledApp {
        IDeviceInstalledApp(bundleIdentifier: bundleIdentifier, name: name ?? bundleIdentifier,
            version: version, applicationIdentifier: nil, installationPath: nil, applicationType: "User",
            isRemovable: nil, registrationDate: registrationDate,
            trackingRestriction: "This app’s installed copy could not be verified. Refresh Installed Apps to try again.")
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

    fileprivate static func canonical(_ path: String) -> String {
        path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }
}

/// A locked read-modify-write transaction over one atomic file outside the library.
public final class IDeviceManagedInstallRegistry: @unchecked Sendable {
    public static let shared = IDeviceManagedInstallRegistry(fileURL:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Ksign/ManagedInstalls.json"))

    private struct FileContents: Codable, Equatable {
        let version: Int
        var records: [IDeviceManagedInstall]
        var serverTransfers: [ServerTransfer]?
    }
    private struct ServerTransfer: Codable, Equatable {
        let observation: IDeviceServerInstallObservation
        var servedAt: Date?
        var registeredCopy: RegisteredCopy? = nil
    }
    private struct RegisteredCopy: Codable, Equatable {
        let path: String?
        let date: Date?

        func matches(_ app: IDeviceInstalledApp) -> Bool {
            if let path {
                return app.installationPath.map(IDeviceServerInstallObservation.canonical) == path
            }
            return date != nil && date == app.registrationDate
        }
    }
    private let fileURL: URL
    private let lockURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
        lockURL = self.fileURL.appendingPathExtension("lock")
    }

    public func snapshot() throws -> [IDeviceManagedInstall] {
        try transaction { $0.records }
    }

    public func inventorySnapshot() throws -> (records: [IDeviceManagedInstall], bundleIdentifiers: Set<String>) {
        try transaction { contents in
            var bundles = Set(contents.records.map(\.bundleIdentifier))
            for transfer in contents.serverTransfers ?? [] where transfer.servedAt != nil {
                bundles.insert(transfer.observation.bundleIdentifier)
            }
            return (contents.records, bundles)
        }
    }

    /// Call only after installation_proxy has confirmed a successful install.
    public func recordConfirmedInstall(_ app: IDeviceInstalledApp,
                                       hostBundleIdentifier: String? = Bundle.main.bundleIdentifier) throws {
        guard app.removalRestriction(hostBundleIdentifier: hostBundleIdentifier) == nil,
              let identity = app.applicationIdentifier, !identity.isEmpty,
              app.installationPath?.isEmpty == false || app.registrationDate != nil else { return }
        let record = IDeviceManagedInstall(token: UUID(), bundleIdentifier: app.id,
            applicationIdentifier: identity, installationPath: app.installationPath.flatMap { $0.isEmpty ? nil : $0 },
            registrationDate: app.registrationDate, installedAt: Date(), name: app.name, version: app.version)
        try transaction { contents in
            contents.records.removeAll { $0.bundleIdentifier == app.id }
            contents.records.append(record)
        }
    }

    public func recordServerOffer(_ observation: IDeviceServerInstallObservation,
                                  hostBundleIdentifier: String? = Bundle.main.bundleIdentifier) throws {
        try recordServerTransfer(observation, servedAt: nil, hostBundleIdentifier: hostBundleIdentifier)
    }

    public func recordServerTransfer(_ observation: IDeviceServerInstallObservation, servedAt: Date,
                                     hostBundleIdentifier: String? = Bundle.main.bundleIdentifier) throws {
        try recordServerTransfer(observation, servedAt: Optional(servedAt), hostBundleIdentifier: hostBundleIdentifier)
    }

    private func recordServerTransfer(_ observation: IDeviceServerInstallObservation, servedAt: Date?,
                                      hostBundleIdentifier: String?) throws {
        guard observation.bundleIdentifier != hostBundleIdentifier, !observation.bundleIdentifier.isEmpty,
              !observation.applicationIdentifier.isEmpty,
              servedAt.map({ observation.startedAt <= $0 }) ?? true else { return }
        try transaction { contents in
            var transfers = contents.serverTransfers ?? []
            if let index = transfers.firstIndex(where: { $0.observation == observation }) {
                guard transfers[index].servedAt == nil, let servedAt else { return }
                transfers[index].servedAt = servedAt
            } else {
                transfers.append(ServerTransfer(observation: observation, servedAt: servedAt))
            }
            contents.serverTransfers = transfers
        }
    }

    /// Keep evidence seen during installation so a later inventory can verify
    /// the same copy, even when iOS supplies a path but no registration date.
    public func recordServerRegistration(_ observation: IDeviceServerInstallObservation,
                                         path: String?, registrationDate: Date?, observedAt: Date = Date()) throws {
        try transaction { contents in
            guard var transfers = contents.serverTransfers,
                  let index = transfers.firstIndex(where: { $0.observation == observation }),
                  let servedAt = transfers[index].servedAt,
                  transfers[index].registeredCopy == nil,
                  observation.sawNewCopy(path: path, registrationDate: registrationDate,
                      servedAt: servedAt, now: observedAt) else { return }
            let path = path.flatMap { $0.isEmpty ? nil : IDeviceServerInstallObservation.canonical($0) }
            transfers[index].registeredCopy = RegisteredCopy(path: path, date: registrationDate)
            contents.serverTransfers = transfers
        }
    }

    /// Call only after a targeted device lookup confirms removal.
    func remove(_ record: IDeviceManagedInstall) throws -> Bool {
        try transaction { contents in
            guard let current = contents.records.first(where: { $0.bundleIdentifier == record.bundleIdentifier }) else {
                return true
            }
            guard current.token == record.token else { return false }
            contents.records.removeAll { $0.token == record.token }
            discardOlderTransfers(for: [record.bundleIdentifier: record.installedAt], in: &contents)
            return true
        }
    }

    /// Inventory can omit an app. Only a separately verified absence can delete
    /// a receipt, and only if that exact receipt existed before this query.
    public func reconcile(_ apps: [IDeviceInstalledApp], observed: [IDeviceManagedInstall],
                          verifiedAbsent: Set<String> = [], hostBundleIdentifier: String?,
                          inventoryStartedAt: Date = Date()) throws -> [IDeviceInstalledApp] {
        try transaction { contents in
            let current = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let observedTokens = Set(observed.map(\.token))
            let previous = Dictionary(uniqueKeysWithValues: contents.records.map { ($0.bundleIdentifier, $0) })
            var removed: [String: Date] = [:]
            contents.records.removeAll { record in
                guard observedTokens.contains(record.token), verifiedAbsent.contains(record.bundleIdentifier),
                      current[record.bundleIdentifier] == nil else { return false }
                removed[record.bundleIdentifier] = record.installedAt
                return true
            }
            discardOlderTransfers(for: removed, in: &contents)
            if let transfers = contents.serverTransfers {
                var promoted: [String: Date] = [:]
                let pending = transfers.sorted { $0.observation.startedAt > $1.observation.startedAt }.filter { transfer in
                    let observation = transfer.observation
                    guard let servedAt = transfer.servedAt, servedAt <= inventoryStartedAt else { return true }
                    guard promoted[observation.bundleIdentifier] == nil else { return false }
                    guard let app = current[observation.bundleIdentifier],
                          app.removalRestriction(hostBundleIdentifier: hostBundleIdentifier) == nil,
                          app.applicationIdentifier == observation.applicationIdentifier,
                          observation.version == nil || app.version == observation.version,
                          transfer.registeredCopy?.matches(app) ?? observation.sawNewCopy(
                            path: app.installationPath, registrationDate: app.registrationDate,
                            servedAt: servedAt, now: inventoryStartedAt) else { return true }
                    let path = app.installationPath.flatMap { $0.isEmpty ? nil : $0 }
                    guard path != nil || app.registrationDate != nil else { return true }
                    guard previous[app.id].map({ $0.installedAt < observation.startedAt }) ?? true else { return false }
                    contents.records.removeAll { $0.bundleIdentifier == app.id }
                    contents.records.append(IDeviceManagedInstall(token: UUID(), bundleIdentifier: app.id,
                        applicationIdentifier: observation.applicationIdentifier, installationPath: path,
                        registrationDate: app.registrationDate,
                        installedAt: max(app.registrationDate ?? servedAt, observation.startedAt),
                        name: app.name, version: app.version))
                    promoted[app.id] = observation.startedAt
                    return false
                }
                contents.serverTransfers = pending.filter { transfer in
                    promoted[transfer.observation.bundleIdentifier].map { transfer.observation.startedAt > $0 } ?? true
                }
            }
            return contents.records.indices.map { index in
                let record = contents.records[index]
                guard let app = current[record.bundleIdentifier], record.matches(app) else {
                    return record.unverifiedApp
                }
                // Upgrade the display details of receipts written by older builds.
                if record.name == nil {
                    contents.records[index].name = app.name
                    contents.records[index].version = app.version
                }
                return app
            }
        }
    }

    private func discardOlderTransfers(for removed: [String: Date], in contents: inout FileContents) {
        guard !removed.isEmpty else { return }
        contents.serverTransfers?.removeAll { transfer in
            guard let installedAt = removed[transfer.observation.bundleIdentifier] else { return false }
            return transfer.servedAt.map { $0 <= installedAt } ?? false
        }
    }

    private func read() throws -> FileContents {
        do {
            let contents = try JSONDecoder().decode(FileContents.self, from: Data(contentsOf: fileURL))
            guard contents.version == 1,
                  Set(contents.records.map(\.bundleIdentifier)).count == contents.records.count,
                  contents.records.allSatisfy({
                      !$0.bundleIdentifier.isEmpty && !$0.applicationIdentifier.isEmpty &&
                          ($0.installationPath?.isEmpty == false || $0.registrationDate != nil)
                  }) else {
                throw IDeviceInstallSkip(reason: "Unsupported or invalid install tracking file.")
            }
            return contents
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return FileContents(version: 1, records: [], serverTransfers: nil)
        } catch {
            throw IDeviceInstallSkip(reason: "Asign couldn't read its installed-app records: \(error.localizedDescription)")
        }
    }

    private func transaction<T>(_ update: (inout FileContents) -> T) throws -> T {
        let descriptor: Int32
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            throw IDeviceInstallSkip(reason: "Asign couldn't open its installed-app records: \(error.localizedDescription)")
        }
        // Lock a separate inode so atomic replacement never invalidates the lock.
        defer { _ = close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            guard code == .EINTR else {
                throw IDeviceInstallSkip(reason: "Asign couldn't lock its installed-app records: \(POSIXError(code).localizedDescription)")
            }
        }
        let original = try read()
        var contents = original
        let result = update(&contents)
        if contents != original {
            do {
                try JSONEncoder().encode(contents).write(to: fileURL, options: .atomic)
            } catch {
                throw IDeviceInstallSkip(reason: "Asign couldn't save its installed-app records: \(error.localizedDescription)")
            }
        }
        return result
    }
}

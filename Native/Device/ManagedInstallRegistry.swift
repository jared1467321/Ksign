import Foundation

/// Proof of a completed Ksign install, tied to that installed copy rather than
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

/// One atomic file outside the library. Workers share this lock so concurrent
/// installs cannot overwrite each other's receipts. Read/write failures fail
/// closed; a failed save never grants permission to uninstall an app.
public final class IDeviceManagedInstallRegistry: @unchecked Sendable {
    public static let shared = IDeviceManagedInstallRegistry(fileURL:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Ksign/ManagedInstalls.json"))

    private struct FileContents: Codable {
        let version: Int
        var records: [IDeviceManagedInstall]
    }
    private let fileURL: URL
    private let lock = NSLock()
    private var records: [IDeviceManagedInstall] = []
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
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A fresh installation has no owned apps yet.
        } catch {
            readFailure = "Ksign couldn't read its installed-app records: \(error.localizedDescription)"
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

    /// Server installs lack a native completion reply. Require an OS-reported
    /// registration change AND later match the final IPA's signing identity.
    public func recordObservedInstall(bundleIdentifier: String, applicationIdentifier: String,
                                      previousRegistrationDate: Date?, registrationDate: Date?,
                                      preparedAt: Date,
                                      hostBundleIdentifier: String? = Bundle.main.bundleIdentifier) throws {
        guard bundleIdentifier != hostBundleIdentifier, !bundleIdentifier.isEmpty,
              !applicationIdentifier.isEmpty, let registrationDate,
              previousRegistrationDate.map({ registrationDate > $0 }) ?? (registrationDate >= preparedAt),
              registrationDate.timeIntervalSince1970.isFinite,
              registrationDate.timeIntervalSince1970 > 0 else { return }
        try store(IDeviceManagedInstall(token: UUID(), bundleIdentifier: bundleIdentifier,
            applicationIdentifier: applicationIdentifier, installationPath: nil,
            registrationDate: registrationDate, installedAt: Date()))
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
                          hostBundleIdentifier: String?) throws -> [IDeviceInstalledApp] {
        lock.lock()
        defer { lock.unlock() }
        try checkReadable()
        let current = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        let retained = records.filter { record in
            guard observed.contains(record) else { return true }
            guard let app = current[record.bundleIdentifier] else { return false }
            guard app.id != hostBundleIdentifier, app.applicationType != "System", app.isRemovable != false else { return false }
            return !record.wasReplaced(by: app)
        }
        if retained != records { try save(retained) }
        return apps.filter { app in
            app.removalRestriction(hostBundleIdentifier: hostBundleIdentifier) == nil &&
                retained.contains { $0.matches(app) }
        }
    }

    private func store(_ record: IDeviceManagedInstall) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkReadable()
        try save(records.filter { $0.bundleIdentifier != record.bundleIdentifier } + [record])
    }

    private func checkReadable() throws {
        if let readFailure { throw IDeviceInstallSkip(reason: readFailure) }
    }

    private func save(_ updated: [IDeviceManagedInstall]) throws {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(FileContents(version: 1, records: updated))
            try data.write(to: fileURL, options: .atomic)
            records = updated
        } catch {
            throw IDeviceInstallSkip(reason: "Ksign couldn't save its installed-app records: \(error.localizedDescription)")
        }
    }
}

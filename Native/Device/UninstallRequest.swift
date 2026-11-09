import Foundation

public enum IDeviceUninstallEvent: Sendable {
    case started(String)
    case finished(String, Result<Bool, Error>)
}

/// Shared admission for a rolling removal batch. Each worker owns its native
/// client; only claiming work, stopping and recording results cross threads.
public final class IDeviceUninstallBatch: @unchecked Sendable {
    public let count: Int
    let registry: IDeviceManagedInstallRegistry
    private let apps: [IDeviceInstalledApp]
    private let lock = NSLock()
    private var nextIndex = 0
    private var stopped = false
    private var completed: [String: Result<Bool, Error>] = [:]

    public init(apps: [IDeviceInstalledApp], registry: IDeviceManagedInstallRegistry = .shared) {
        var seen = Set<String>()
        self.apps = apps.filter { seen.insert($0.id).inserted }
        count = self.apps.count
        self.registry = registry
    }

    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    public var results: [String: Result<Bool, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    func next() -> IDeviceInstalledApp? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, nextIndex < apps.count else { return nil }
        defer { nextIndex += 1 }
        return apps[nextIndex]
    }

    func record(_ id: String, result: Result<Bool, Error>) {
        lock.lock()
        completed[id] = result
        lock.unlock()
    }
}

/// Capture the app the user reviewed in the device list. Recheck that snapshot
/// immediately before removal without requiring a locally saved signed app.
public struct IDeviceUninstallRequest: Sendable {
    public let bundleIdentifier: String
    let managedInstall: IDeviceManagedInstall
    let registry: IDeviceManagedInstallRegistry

    public init(installedApp: IDeviceInstalledApp, hostBundleIdentifier: String? = Bundle.main.bundleIdentifier,
                registry: IDeviceManagedInstallRegistry = .shared) throws {
        if let reason = installedApp.removalRestriction(hostBundleIdentifier: hostBundleIdentifier) {
            throw IDeviceInstallSkip(reason: reason)
        }
        bundleIdentifier = installedApp.bundleIdentifier
        guard let record = try registry.snapshot().first(where: { $0.matches(installedApp) }) else {
            throw IDeviceInstallSkip(reason: "This installed copy isn't verified as installed by Asign. Refresh Installed Apps before trying again.")
        }
        managedInstall = record
        self.registry = registry
    }

    /// False means already absent. If iOS reports a different identity now, the
    /// user must refresh and review that copy before sending another command.
    func validate(_ installed: IDeviceInstalledApp?, hostBundleIdentifier: String?) throws -> Bool {
        guard bundleIdentifier != hostBundleIdentifier else {
            throw IDeviceInstallSkip(reason: "Asign cannot uninstall itself. Remove it from the Home Screen if needed.")
        }
        guard let installed else { return false }
        if let reason = installed.removalRestriction(hostBundleIdentifier: hostBundleIdentifier) {
            throw IDeviceInstallSkip(reason: reason)
        }
        guard try registry.snapshot().contains(managedInstall), managedInstall.matches(installed) else {
            throw IDeviceInstallSkip(reason: "The selected app changed or could not be verified. Refresh Installed Apps and review it again before uninstalling.")
        }
        return true
    }

    /// Called only after the device confirms absence. A newer receipt for the
    /// same bundle ID must not be deleted by a stale removal completion.
    func didRemove() throws {
        do { try registry.remove(managedInstall) }
        catch {
            throw IDeviceInstallSkip(reason: "The app is uninstalled, but its tracking record couldn't be saved. Refresh Installed Apps to clear it. \(error.localizedDescription)")
        }
    }
}

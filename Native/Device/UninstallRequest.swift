import Foundation

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
            throw IDeviceInstallSkip(reason: "This installed copy isn't verified as installed by Ksign. Refresh Installed Apps before trying again.")
        }
        managedInstall = record
        self.registry = registry
    }

    /// False means already absent. If iOS reports a different identity now, the
    /// user must refresh and review that copy before sending another command.
    func validate(_ installed: IDeviceInstalledApp?, hostBundleIdentifier: String?) throws -> Bool {
        guard bundleIdentifier != hostBundleIdentifier else {
            throw IDeviceInstallSkip(reason: "Ksign cannot uninstall itself. Remove it from the Home Screen if needed.")
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

import Foundation

/// Capture the app the user reviewed in the device list. Recheck that snapshot
/// immediately before removal without requiring a locally saved signed app.
public struct IDeviceUninstallRequest: Sendable {
    public let bundleIdentifier: String
    let applicationIdentifier: String?

    public init(installedApp: IDeviceInstalledApp, hostBundleIdentifier: String? = Bundle.main.bundleIdentifier) throws {
        if let reason = installedApp.removalRestriction(hostBundleIdentifier: hostBundleIdentifier) {
            throw IDeviceInstallSkip(reason: reason)
        }
        bundleIdentifier = installedApp.bundleIdentifier
        applicationIdentifier = installedApp.applicationIdentifier
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
        guard installed.bundleIdentifier == bundleIdentifier,
              applicationIdentifier == nil || installed.applicationIdentifier == applicationIdentifier else {
            throw IDeviceInstallSkip(reason: "The selected app changed or could not be verified. Refresh Installed Apps and review it again before uninstalling.")
        }
        return true
    }
}

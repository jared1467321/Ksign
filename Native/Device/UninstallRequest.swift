import Foundation

/// Removal requires a known signing identity from the selected signed artifact.
/// A bundle ID alone could accidentally target a different installed copy.
public struct IDeviceUninstallRequest: Sendable {
    public let bundleIdentifier: String
    let applicationIdentifier: String

    public init(bundleIdentifier: String, executableURL: URL) throws {
        guard let identity = try MachOSigningIdentity.read(executableURL)?.applicationIdentifier else {
            throw IDeviceInstallSkip(reason: "The signed app's identity could not be verified. Sign it again before uninstalling from Ksign.")
        }
        try self.init(bundleIdentifier: bundleIdentifier, applicationIdentifier: identity)
    }

    init(bundleIdentifier: String, applicationIdentifier: String) throws {
        guard !bundleIdentifier.isEmpty, !bundleIdentifier.contains("\0"),
              bundleIdentifier == bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
              applicationIdentifier.hasSuffix("." + bundleIdentifier),
              applicationIdentifier.count > bundleIdentifier.count + 1 else {
            throw IDeviceInstallSkip(reason: "The signed app's bundle identifier and signing identity do not match.")
        }
        self.bundleIdentifier = bundleIdentifier
        self.applicationIdentifier = applicationIdentifier
    }

    /// False means already absent. Unknown or different identities fail closed.
    func validate(_ installed: IDeviceInstalledApplication?, hostBundleIdentifier: String?) throws -> Bool {
        guard bundleIdentifier != hostBundleIdentifier else {
            throw IDeviceInstallSkip(reason: "Ksign cannot uninstall itself. Remove it from the Home Screen if needed.")
        }
        guard let installed else { return false }
        guard installed.bundleIdentifier == bundleIdentifier,
              installed.applicationIdentifier == applicationIdentifier else {
            throw IDeviceInstallSkip(reason: "The installed app's signing identity does not match this signed copy. Remove it from the Home Screen if you intend to delete that copy.")
        }
        return true
    }
}

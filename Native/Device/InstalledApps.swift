import Foundation

/// A device-reported snapshot, independent of Ksign's library and IPA files.
public struct IDeviceInstalledApp: Decodable, Identifiable, Sendable {
    public let bundleIdentifier: String
    public let name: String
    public let version: String?
    public let applicationIdentifier: String?
    public let applicationType: String?
    public let isRemovable: Bool?
    public var id: String { bundleIdentifier }

    public func removalRestriction(hostBundleIdentifier: String?) -> String? {
        if bundleIdentifier == hostBundleIdentifier {
            return "Ksign cannot uninstall itself. Remove it from the Home Screen if needed."
        }
        if applicationType != "User" || isRemovable == false {
            return "iOS does not allow Ksign to remove this app."
        }
        if bundleIdentifier.isEmpty || bundleIdentifier.contains("\0") ||
            bundleIdentifier.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return "The installed app's bundle identifier is invalid. Refresh the installed-app list."
        }
        return nil
    }
}

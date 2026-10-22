import Foundation

/// A device-reported snapshot, independent of Ksign's library and IPA files.
public struct IDeviceInstalledApp: Decodable, Identifiable, Sendable {
    public let bundleIdentifier: String
    public let name: String
    public let version: String?
    public let applicationIdentifier: String?
    public let installationPath: String?
    public let applicationType: String?
    public let isRemovable: Bool?
    public var registrationDate: Date?
    public var id: String { bundleIdentifier }

    /// Newest device registration first, unknown dates last. Stable ties keep
    /// the list from jumping when dates are unavailable or shared by a batch.
    public static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        switch (lhs.registrationDate, rhs.registrationDate) {
        case let (left?, right?) where left != right: return left > right
        case (.some, .none): return true
        case (.none, .some): return false
        default:
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

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

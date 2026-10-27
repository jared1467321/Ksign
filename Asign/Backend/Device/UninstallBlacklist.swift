import Combine
import Foundation
import IDeviceSwift

@MainActor
final class UninstallBlacklist: ObservableObject {
    static let shared = UninstallBlacklist()
    private static let storageKey = "Ksign.uninstallBlacklist"

    // Bundle identifiers keep protection stable across app updates and reloads.
    @Published private(set) var entries: [String: String]
    private let defaults: UserDefaults
    private var defaultsObserver: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
        defaultsObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reload() }
            }
    }

    func contains(_ bundleIdentifier: String) -> Bool {
        entries[bundleIdentifier] != nil
    }

    func add(_ app: IDeviceInstalledApp) {
        reload()
        var updated = entries
        updated[app.id] = app.name
        defaults.set(updated, forKey: Self.storageKey)
        entries = updated
    }

    func remove(_ bundleIdentifier: String) {
        reload()
        var updated = entries
        updated.removeValue(forKey: bundleIdentifier)
        defaults.set(updated, forKey: Self.storageKey)
        entries = updated
    }

    func reload() {
        let saved = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
        if entries != saved { entries = saved }
    }

    func checkRemovalAllowed(for bundleIdentifier: String) throws {
        // Read the saved setting again after any connection/queue waits.
        reload()
        guard !contains(bundleIdentifier) else {
            throw IDeviceInstallSkip(reason: "This app is on the uninstall blacklist. Remove it in Settings → Blacklisted Apps before uninstalling.")
        }
    }
}

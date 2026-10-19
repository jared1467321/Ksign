import Foundation

protocol AppInfoPresentable {
    var uuid: String? { get }
    var name: String? { get }
    var identifier: String? { get }
}
struct Options { var appIdentifier: String? }
struct Signed: AppInfoPresentable {
    let uuid: String?
    let name: String?
    let identifier: String?
    let archive: URL?
    let directory: URL?
}
final class NSFetchRequest<T> {
    var predicate: NSPredicate?
    init(entityName: String) {}
}
extension NSPredicate {
    convenience init(format: String, _ ids: [String]) { self.init(value: true) }
}
final class Storage {
    static let shared = Storage()
    var apps: [Signed] = []
    var context: Storage { self }
    func fetch<T>(_ request: NSFetchRequest<T>) throws -> [T] { apps as! [T] }
    func getArchiveURL(for app: AppInfoPresentable) -> URL? { (app as? Signed)?.archive }
    func getAppDirectory(for app: AppInfoPresentable) -> URL? { (app as? Signed)?.directory }
}
enum UIApplication {
    static var installed: Set<String> = []
    static func isAppInstalled(_ id: String) -> Bool { installed.contains(id) }
}
struct UIAlertAction {
    enum Style { case cancel, `default` }
    let title: String
    let handler: (UIAlertAction) -> Void
    init(title: String, style: Style, handler: @escaping (UIAlertAction) -> Void) {
        self.title = title; self.handler = handler
    }
    func tap() { handler(self) }
}
enum UIAlertController {
    static var actions: [UIAlertAction] = []
    static var message = ""
    static func showAlert(title: String, message: String, actions: [UIAlertAction]) {
        self.message = message; self.actions = actions
    }
}
@MainActor final class DeviceInstallationManager {
    static let shared = DeviceInstallationManager()
    var identities: [String: String] = [:]
    var validated: [String] = []
    var workflows: Set<UUID> = []
    var retains = 0
    func clearSetupFailure() {}
    func retainWorkflow(_ id: UUID) { workflows.insert(id); retains += 1 }
    func releaseWorkflow(_ id: UUID) { workflows.remove(id) }
    func validate(_ preflight: IDeviceInstallPreflight) async throws {
        validated.append(preflight.bundleIdentifier)
        try preflight.validateInstalledApplication(.init(bundleIdentifier: preflight.bundleIdentifier,
            applicationIdentifier: identities[preflight.bundleIdentifier]))
    }
}

@main struct SigningReviewTests {
    @MainActor static func waitForAlert() async throws {
        let deadline = Date().addingTimeInterval(5)
        while UIAlertController.actions.isEmpty {
            precondition(Date() < deadline)
            await Task.yield()
        }
    }
    @MainActor static func main() async throws {
        let defaults = UserDefaults.standard
        let originalMethod = defaults.object(forKey: "Feather.installationMethod")
        defer { defaults.set(originalMethod, forKey: "Feather.installationMethod") }
        defaults.set(1, forKey: "Feather.installationMethod")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pad = directory.appendingPathComponent("pad.ipa")
        let store = directory.appendingPathComponent("store.ipa")
        let tv = directory.appendingPathComponent("tv.ipa")
        func info(_ id: String, platform: String = "iPhoneOS", family: [Int] = [1]) -> [String: Any] {
            ["CFBundleIdentifier": id, "CFBundleExecutable": "App",
             "CFBundleSupportedPlatforms": [platform], "UIDeviceFamily": family]
        }
        ArchiveBackedApp.archives = [
            pad.path: (info("app.pad", family: [2]), try InstallPreflightTests.signedBinary("TEAM.app.pad")),
            store.path: (info("app.store"), try InstallPreflightTests.signedBinary("TEAM.app.store")),
            tv.path: (info("app.tv", platform: "AppleTVOS"), try InstallPreflightTests.signedBinary("TEAM.app.tv")),
        ]
        try PropertyListSerialization.data(fromPropertyList: info("app.legacy"), format: .binary, options: 0)
            .write(to: directory.appendingPathComponent("Info.plist"))
        try InstallPreflightTests.signedBinary("TEAM.app.legacy").write(to: directory.appendingPathComponent("App"))
        let apps = [Signed(uuid: "pad-id", name: "Pad", identifier: "app.pad", archive: pad, directory: nil),
                    Signed(uuid: "store-id", name: "Store", identifier: "app.store", archive: store, directory: nil),
                    Signed(uuid: "tv-id", name: "TV", identifier: "app.tv", archive: tv, directory: nil),
                    Signed(uuid: "legacy-id", name: "Legacy", identifier: "app.legacy", archive: nil, directory: directory)]
        Storage.shared.apps = apps
        UIApplication.installed = ["app.pad", "app.store"]
        let manager = DeviceInstallationManager.shared
        manager.identities = ["app.pad": "TEAM.app.pad", "app.store": "STORE.app.store"]
        let sources = apps.prefix(3).map { SigningPreflight.source(for: $0) }
        var report: SigningPreflight.Report?
        var returnedToEditing = false
        SigningPreflightCoordinator.review(sources) { report = $0 } onCancel: { returnedToEditing = true }
        try await waitForAlert()
        precondition(UIAlertController.actions.map(\.title) == ["Cancel", "Edit Bundle IDs", "Continue Signing"])
        precondition(UIAlertController.message.contains("App Store") && UIAlertController.message.contains("app.pad"))
        precondition(manager.retains == 0 && manager.validated.isEmpty,
                     "The signing warning must not set up a device connection")
        UIAlertController.actions[1].tap()
        precondition(returnedToEditing && report == nil, "Editing IDs must not start signing")
        UIAlertController.actions = []
        SigningPreflightCoordinator.review(sources) { report = $0 } onCancel: { }
        try await waitForAlert()
        UIAlertController.actions[2].tap()
        precondition(report?.eligibleIndices == [0, 1], "Continue Signing retains installed apps and iPad-only apps")
        precondition(report?.skipped.count == 1)

        let result = await SigningPreflightCoordinator.prepareInstallation(["pad-id", "store-id", "tv-id", "missing-id", "legacy-id"])
        precondition(result.appIDs == ["pad-id", "legacy-id"], "Only the exact eligible signed IDs enter the drawer")
        precondition(result.withheld.count == 3)
        precondition(manager.validated == ["app.pad", "app.store"])
        precondition(manager.retains == 1 && manager.workflows.isEmpty, "One read-only workflow must clean up after the batch")
        precondition(Storage.shared.apps.count == 4, "All successful signed packages must remain in the library")
        print("Passed signing review choices, local installed-ID warnings, iPad eligibility and exact signing-to-install handoff with preserved packages")
    }
}

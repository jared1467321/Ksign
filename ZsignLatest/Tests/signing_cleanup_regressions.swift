import Foundation

protocol AppInfoPresentable {
    var uuid: String? { get }
    var name: String? { get }
    var isSigned: Bool { get }
}
struct TestApp: AppInfoPresentable {
    let uuid: String?
    var name: String? { uuid }
    let isSigned: Bool
    let failAt: String?
}
struct Options { var removeApp: Bool; var onlyModify = false }
struct UIImage {}
struct CertificatePair {}
struct TweakPackageCache {}
struct ZsignSigningSession {}
struct IDeviceInstallSkip: Error { let reason: String }
enum TestError: Error { case expected }

// Delay UI callbacks deliberately: background/bulk completion must be sufficient
// to remove the source, without relying on a signing screen receiving callbacks.
enum DispatchQueue {
    static var main: DispatchQueue { .init() }
    static let lock = NSLock()
    static var pending: [() -> Void] = []
    case queue
    init() { self = .queue }
    func async(execute: @escaping () -> Void) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.pending.append(execute)
    }
    func asyncAfter(deadline: DispatchTime, execute: @escaping () -> Void) { async(execute: execute) }
    static func discard() {
        lock.lock(); defer { lock.unlock() }
        pending = []
    }
    @MainActor static func drain() {
        lock.lock(); let callbacks = pending; pending = []; lock.unlock()
        callbacks.forEach { $0() }
    }
}

final class Storage {
    static let shared = Storage()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var deleted: [String] = []
    func file(_ id: String) -> URL { directory.appendingPathComponent(id) }
    func getArchiveURL(for app: AppInfoPresentable) -> URL? { nil }
    @MainActor func deleteApp(for app: AppInfoPresentable) {
        MainActor.preconditionIsolated()
        precondition(FileManager.default.fileExists(atPath: file("signed-" + app.uuid!).path),
                     "Publish the signed result before removing its source")
        try! FileManager.default.removeItem(at: file(app.uuid!))
        deleted.append(app.uuid!)
    }
}
struct ArchiveBackedApp {
    let archiveURL: URL
    var archiveIndex: ArchiveBackedApp { self }
    init(archiveURL: URL) throws { self.archiveURL = archiveURL }
    func validate() throws {}
}
enum ArchiveBackedAppError: Error { case invalidArchive }
enum SigningPreflight {
    struct Issue {
        let name: String
        let reason: String
        var description: String { name + reason }
    }
    static func checkPlatform(for app: AppInfoPresentable, archiveApp: ArchiveBackedApp?) throws {
        if (app as! TestApp).failAt == "preflight" { throw TestError.expected }
    }
}
enum SigningPreflightCoordinator {
    struct Handoff { var appIDs: [String] = []; var withheld: [SigningPreflight.Issue] = [] }
    static func prepareInstallation(_ ids: [String]) async -> Handoff { Handoff(appIDs: ids) }
}
final class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()
    enum Work { case signing }
    func begin(_ work: Work) {}
    func end(_ work: Work, success: Bool) {}
    func claim(_ work: Work) {}
    func release(_ work: Work, success: Bool) {}
    func clearReport(_ work: Work) {}
    func report(_ work: Work, completed: Int, total: Int, fraction: Double?, detail: String, currentItem: String? = nil) {}
}
actor TempMaintenance {
    static let shared = TempMaintenance()
    func beginOperation() {}
    func endOperation() {}
}
final class SigningHandler {
    let app: TestApp
    var signedAppID: String { "signed-" + app.uuid! }
    var appCertificate: CertificatePair?
    var appIcon: UIImage?
    init(app: AppInfoPresentable, options: Options, packages: TweakPackageCache, signingSession: ZsignSigningSession) {
        self.app = app as! TestApp
    }
    func stage(_ name: String) throws { if app.failAt == name { throw TestError.expected } }
    func copy(archiveApp: ArchiveBackedApp?) async throws { try stage("copy") }
    func modify(finish: Bool) async throws { precondition(!finish); try stage("sign") }
    func move() async throws { try stage("archive") }
    func addToDatabase() async throws {
        try stage("database")
        try Data("signed".utf8).write(to: Storage.shared.file(signedAppID))
    }
    func clean() async throws {}
}
struct UIImpactFeedbackGenerator {
    enum Style { case light }
    init(style: Style) {}
    func impactOccurred() {}
}
extension String { static func localized(_ text: String) -> String { text } }
enum UIAlertController {
    static func showAlertWithOk(title: String, message: String, action: () -> Void) { action() }
}
@propertyWrapper struct Cell<T> {
    final class Box { var value: T; init(_ value: T) { self.value = value } }
    let box: Box
    init(wrappedValue: T) { box = Box(wrappedValue) }
    var wrappedValue: T { get { box.value } nonmutating set { box.value = newValue } }
}
struct AppSignConfig {
    let app: AppInfoPresentable
    let options: Options
    var icon: UIImage? { nil }
}

// PRODUCTION_GATES
enum FR {
    // PRODUCTION_SIGN
}
@MainActor struct BulkSigningView {
    @Cell var _isSigning = true
    var signAndInstall = false
    let finished: () -> Void
    func dismiss() { finished() }
    // PRODUCTION_BULK
    func run(_ configs: [AppSignConfig]) async {
        await withCheckedContinuation { continuation in
            let view = BulkSigningView(finished: { continuation.resume() })
            view._runSigning(configs: configs, certificate: nil, skipped: [],
                             archiveApps: configs.map { _ in nil })
        }
    }
}

@main struct SigningCleanupRegressions {
    @MainActor static func main() async throws {
        let storage = Storage.shared
        try FileManager.default.createDirectory(at: storage.directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storage.directory) }
        func config(_ id: String, remove: Bool = true, signed: Bool = false, fail: String? = nil) throws -> AppSignConfig {
            try Data("source".utf8).write(to: storage.file(id))
            return AppSignConfig(app: TestApp(uuid: id, isSigned: signed, failAt: fail), options: Options(removeApp: remove))
        }
        func exists(_ id: String) -> Bool { FileManager.default.fileExists(atPath: storage.file(id).path) }
        // Verify the worker's exact background handoff, without UI completion.
        let single = try config("worker")
        let result: (Error?, String?) = await withCheckedContinuation { continuation in
            FR.signPackageFile(single.app, using: single.options, icon: nil, certificate: nil,
                backgroundCompletion: { continuation.resume(returning: ($0, $1)) }) { _, _ in
                    preconditionFailure("UI delivery is deliberately suspended")
                }
        }
        precondition(result.0 == nil && result.1 == "signed-worker")
        precondition(!exists("worker") && exists("signed-worker"), "Worker success must include source removal")
        // Drop this test callback; bulk UI callbacks below are no-ops.
        DispatchQueue.discard()

        var configs = try [config("one"), config("two"), config("keep", remove: false),
                           config("resign", signed: true)]
        for stage in ["preflight", "copy", "sign", "archive", "database"] {
            configs.append(try config("failed-" + stage, fail: stage))
        }
        await BulkSigningView(finished: {}).run(configs)
        precondition(Set(storage.deleted) == ["worker", "one", "two"])
        for id in ["one", "two"] { precondition(!exists(id) && exists("signed-" + id)) }
        for id in ["keep", "resign"] { precondition(exists(id) && exists("signed-" + id)) }
        for stage in ["preflight", "copy", "sign", "archive", "database"] {
            precondition(exists("failed-" + stage), "Failures must preserve downloads")
        }
        DispatchQueue.drain()
        precondition(Set(storage.deleted) == ["worker", "one", "two"], "UI delivery must not delete twice")
        print("Passed worker/bulk cleanup before completion, disabled removal, signed inputs, and failure preservation.")
    }
}

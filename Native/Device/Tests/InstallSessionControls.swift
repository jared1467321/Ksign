import Foundation

// The runner inserts production session, status handling, busy checks, and
// library selection methods. Only platform/UI and installation services below
// are doubled; no device, server, or library file is touched.
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
protocol ObservableObject {}
struct Animation { static func easeInOut(duration: Double) -> Self { Self() } }
func withAnimation(_ animation: Animation, _ action: () -> Void) { action() }
enum UIApplication {
    struct Application { let applicationState = State.background }
    enum State { case active, background }
    static let shared = Application()
    static let willResignActiveNotification = Notification.Name("inactive")
    static let didEnterBackgroundNotification = Notification.Name("background")
    static let didBecomeActiveNotification = Notification.Name("active")
}
struct Logger {
    static let misc = Logger()
    func error(_ message: String) {}
}
protocol AppInfoPresentable {
    var uuid: String? { get }
    var identifier: String? { get }
    var name: String? { get }
}
struct TestApp: AppInfoPresentable {
    let uuid: String?
    let identifier: String? = "same.bundle"
    var name: String? { uuid }
}
final class InstallerStatusViewModel {
    enum InstallerStatus {
        case none, ready, sendingManifest, sendingPayload, installing
        case completed(Result<Void, Error>)
        case broken(Error)
    }
    var status: InstallerStatus = .none
    var overallProgress = 0.0
}
final class ServerInstaller {
    var shutdowns = 0
    func shutDown() { shutdowns += 1 }
}
struct ServerInstallProgressMonitor {
    static let shared = ServerInstallProgressMonitor()
    func stop(id: UUID) {}
}
@MainActor final class DeviceInstallationManager {
    static let shared = DeviceInstallationManager()
    var workflows: Set<UUID> = []
    func retainWorkflow(_ id: UUID) { workflows.insert(id) }
    func releaseWorkflow(_ id: UUID) { workflows.remove(id) }
    func clearSetupFailure() {}
}
@MainActor final class BackgroundTaskManager {
    enum Owner { case bulkInstalls }
    static let shared = BackgroundTaskManager()
    var claimed = false
    func claim(_ owner: Owner) { claimed = true }
    func release(_ owner: Owner, success: Bool) { claimed = false }
}
final class BulkInstallLiveActivityReporter {
    static let shared = BulkInstallLiveActivityReporter()
    func reset() {}
    func register(_ id: UUID, name: String?) {}
    func remove(_ id: UUID) {}
    func setPaused(_ paused: Bool) {}
    func finish() {}
}
@MainActor final class InstallQueueCoordinator {
    static let shared = InstallQueueCoordinator()
    var activeCount = 0
    var isPaused = false
    func setMaxConcurrent(_ count: Int) {}
    func setPaused(_ paused: Bool) { isPaused = paused }
}
struct StatusEpoch { func cancel() {} }
final class Attempt { func cancel() {} }
@MainActor final class InstallJob {
    let id = UUID()
    let app: AppInfoPresentable
    enum Phase { case queued, running, completed, failed }
    enum BatchRole { case none, pending, awaiting, host, member }
    var phase: Phase = .queued
    var batchRole: BatchRole = .none
    var hasStarted = false
    let isDeviceInstall: Bool
    var isSelfUpdate: Bool { false }
    var isStuckAtPrompt: Bool { isInFlightGroupMember }
    let viewModel = InstallerStatusViewModel()
    var installer: ServerInstaller?
    var cancellations = 0
    var promptCount = 0
    var archiveCleanups = 0
    var _holdsSlot = false
    var _packagingTask: Task<Void, Never>?
    var _packagingAttempt: Attempt?
    var _installTask: Task<Void, Never>?
    let _statusEpoch = StatusEpoch()
    let _serverMethod: Int
    init(app: AppInfoPresentable) throws {
        self.app = app
        isDeviceInstall = UserDefaults.standard.integer(forKey: "Feather.installationMethod") == 1
        _serverMethod = UserDefaults.standard.integer(forKey: "Feather.serverMethod")
        if !isDeviceInstall && _serverMethod == 0 { batchRole = .pending }
    }
    func start() { hasStarted = true }
    func begin() {
        phase = .running
        _holdsSlot = true
        InstallQueueCoordinator.shared.activeCount += 1
    }
    func cancel() { cancellations += 1; _releaseSlotIfNeeded() }
    func retry() { phase = .queued }
    func rejoinPool() { batchRole = .awaiting; phase = .running }
    func becomeBatchHost(memberInstallers: [ServerInstaller]) { batchRole = .host }
    func becomeBatchMember(host: InstallJob) { batchRole = .member }
    func fireBatchedPrompt() { promptCount += 1 }
    func _triggerReadyAction() { promptCount += 1 }
    func _cleanupArchive() { archiveCleanups += 1 }
    func _releaseSlotIfNeeded() {
        if _holdsSlot { InstallQueueCoordinator.shared.activeCount -= 1 }
        _holdsSlot = false
    }
    // PRODUCTION_JOB_METHODS
    func deliver(_ status: InstallerStatusViewModel.InstallerStatus) { _handleStatus(status) }
}
enum EditMode { case active, inactive }
@MainActor final class LibrarySelection {
    var _selectedTab = 0
    var _searchText = "hidden by search"
    var _selectedApps: Set<String> = ["unrelated"]
    var _signedApps: [TestApp] = []
    var _isEditMode = EditMode.inactive
    var _pendingInstalledSelection: InstallSession.InstalledAppsSelectionRequest?
    // PRODUCTION_LIBRARY_METHODS
    func receive(_ request: InstallSession.InstalledAppsSelectionRequest) {
        _receiveInstalledSelection(request)
    }
    func tabChanged() {
        // PRODUCTION_TAB_CHANGE
    }
}
enum TestFailure: Error { case failed }

@main struct InstallSessionControlsTests {
    @MainActor static func main() async throws {
        let session = InstallSession.shared
        let defaults = UserDefaults.standard
        let original = ["Feather.installationMethod", "Feather.serverMethod", "Feather.batchGroupSize"]
            .map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in original {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(2, forKey: "Feather.batchGroupSize")

        // Same partial-batch workflow for native, local server, and external
        // server. Running jobs settle, queued jobs remain intact until cancel.
        for (method, server) in [(1, 0), (0, 0), (0, 1)] {
            defaults.set(method, forKey: "Feather.installationMethod")
            defaults.set(server, forKey: "Feather.serverMethod")
            session.start(apps: (0..<4).map { TestApp(uuid: "app\($0)") })
            let jobs = session.jobs
            jobs[0].begin()
            jobs[1].begin()
            session.togglePause()
            precondition(InstallQueueCoordinator.shared.isPaused)
            precondition(!session.canCancelAndSelectInstalled)
            session.cancelAndSelectInstalled()
            precondition(session.jobs.count == 4, "Cancel must wait for running work")
            jobs[0].deliver(.completed(.success(())))
            jobs[1].deliver(.completed(.failure(TestFailure.failed)))
            precondition(session.canCancelAndSelectInstalled)
            precondition(session.completedCount == 1 && session.installedAppIDs == ["app0"])
            if method == 0 && server == 0 {
                precondition(!jobs[2].hasStarted && !jobs[3].hasStarted,
                             "Completion while paused must not admit the next batch")
            }
            jobs[0].deliver(.completed(.success(())))
            jobs[0].deliver(.broken(TestFailure.failed))
            precondition(jobs[0].phase == .completed && session.completedCount == 1,
                         "Late callbacks must not change successful results")
            session.cancelAndSelectInstalled()
            precondition(session.jobs.isEmpty && !session.isActive && !session.isPaused)
            precondition(!BackgroundTaskManager.shared.claimed)
            precondition(DeviceInstallationManager.shared.workflows.isEmpty)
            precondition(session.installedSelectionRequest?.appIDs == ["app0"])
            precondition(jobs.allSatisfy { $0.cancellations == 1 })
            jobs[2].phase = .completed
            session.jobDidFinish(jobs[2])
            precondition(session.installedAppIDs.isEmpty, "Ignore callbacks from removed jobs")
            session.consumeInstalledSelection(session.installedSelectionRequest!.id)
        }

        // A parked server package can be discarded without forcing another
        // prompt. Native cleanup remains a blocker even after UI completion.
        defaults.set(0, forKey: "Feather.installationMethod")
        defaults.set(0, forKey: "Feather.serverMethod")
        session.start(apps: [TestApp(uuid: "parked")])
        let parked = session.jobs[0]
        parked.begin()
        session.togglePause()
        parked.deliver(.ready)
        precondition(parked.batchRole == .awaiting && parked.promptCount == 0)
        precondition(session.waitingCount == 1 && session.runningCount == 0 && session.canCancelAndSelectInstalled)
        session.togglePause()
        precondition(parked.promptCount == 1 && !session.canCancelAndSelectInstalled)
        session.togglePause()
        precondition(!session.canCancelAndSelectInstalled, "Active manifest must finish first")
        parked.deliver(.completed(.success(())))
        session.cancelAndSelectInstalled()
        session.consumeInstalledSelection(session.installedSelectionRequest!.id)

        defaults.set(1, forKey: "Feather.installationMethod")
        session.start(apps: [TestApp(uuid: "native"), TestApp(uuid: "later")])
        let native = session.jobs[0]
        native.begin()
        session.togglePause()
        native.deliver(.completed(.success(())))
        InstallQueueCoordinator.shared.activeCount = 1 // native cleanup still owns its slot
        precondition(!session.canCancelAndSelectInstalled)
        InstallQueueCoordinator.shared.activeCount = 0
        native._packagingTask = Task {}
        precondition(!session.canCancelAndSelectInstalled, "Wait for the native attempt's final delivery")
        native._packagingTask = nil
        session.cancelAndSelectInstalled()

        // Tab switching and onAppear can arrive before SwiftUI's onChange.
        // Apply after the switch and keep the request for a lazily-created view.
        let request = session.installedSelectionRequest!
        let library = LibrarySelection()
        library._signedApps = [TestApp(uuid: "native"), TestApp(uuid: "later"), TestApp(uuid: "other-copy")]
        library.receive(request)
        library.receive(request) // onAppear during navigation
        precondition(session.installedSelectionRequest != nil)
        library.tabChanged()
        precondition(library._selectedTab == 1 && library._isEditMode == .active)
        precondition(library._selectedApps == ["native"] && library._searchText.isEmpty)
        precondition(session.installedSelectionRequest == nil)
        library.receive(.init(appIDs: ["later", "already-deleted"]))
        precondition(library._selectedApps == ["later"], "Replace selection and ignore deleted signed records")

        session.start(apps: [TestApp(uuid: "early"), TestApp(uuid: "late"), TestApp(uuid: "remaining")])
        let early = session.jobs[0], late = session.jobs[1]
        early.begin()
        late.begin()
        early.deliver(.completed(.success(())))
        try await Task.sleep(nanoseconds: 2_000_000_000)
        precondition(!session.jobs.contains { $0 === early })
        session.togglePause()
        late.deliver(.completed(.success(())))
        session.cancelAndSelectInstalled()
        precondition(session.installedSelectionRequest?.appIDs == ["early", "late"],
                     "Partial batches must include successes whose rows already retired")
        session.consumeInstalledSelection(session.installedSelectionRequest!.id)

        // Retired successes must remain selectable, including after the entire
        // queue finishes. A new queue clears history and starts unpaused.
        session.start(apps: [TestApp(uuid: "finished")])
        precondition(session.installedAppIDs.isEmpty && !session.isPaused)
        let finished = session.jobs[0]
        finished.begin()
        finished.deliver(.completed(.success(())))
        try await Task.sleep(nanoseconds: 2_000_000_000)
        precondition(session.jobs.isEmpty && session.isFinished && session.isDrawerAvailable && !session.isActive)
        precondition(session.installedAppIDs == ["finished"] && session.canCancelAndSelectInstalled)
        session.cancelAndSelectInstalled()
        precondition(session.installedSelectionRequest?.appIDs == ["finished"])
        session.consumeInstalledSelection(session.installedSelectionRequest!.id)

        session.start(apps: [TestApp(uuid: "never-started")])
        session.togglePause()
        session.cancelAndSelectInstalled()
        precondition(session.installedSelectionRequest?.appIDs.isEmpty == true)
        precondition(!InstallQueueCoordinator.shared.isPaused && !session.isActive)
        print("Passed install pause/drain/cancel, success tracking, retirement, and Signed selection scenarios")
    }
}

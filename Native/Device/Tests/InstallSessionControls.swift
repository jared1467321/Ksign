import Foundation

// The runner inserts production session, status handling, busy checks, and
// library selection methods. Only platform/UI and installation services below
// are doubled; no device, server, or library file is touched.
@propertyWrapper struct Published<Value> {
    private var value: Value
    var wrappedValue: Value {
        get { value }
        set { value = newValue; PublicationMetrics.count += 1 }
    }
    init(wrappedValue: Value) { self.value = wrappedValue }
}
enum PublicationMetrics { static var count = 0 }
enum ForegroundReadMetrics {
    static var phases = 0
    static var progress = 0
    static func reset() { phases = 0; progress = 0 }
}
@propertyWrapper struct CountedPhaseRead<Value> {
    private var value: Value
    var wrappedValue: Value {
        get { ForegroundReadMetrics.phases += 1; return value }
        set { value = newValue }
    }
    init(wrappedValue: Value) { self.value = wrappedValue }
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
    private var progress = 0.0
    var overallProgress: Double {
        get { ForegroundReadMetrics.progress += 1; return progress }
        set { progress = newValue }
    }
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
    var hasDeviceWorkInProgress = false
    var isPaused = false
    var maxConcurrent = 3
    var isNativeInstall = false
    func setMaxConcurrent(_ count: Int) { maxConcurrent = count }
    func setNativeInstallMode(_ enabled: Bool) { isNativeInstall = enabled }
    func setPaused(_ paused: Bool) { isPaused = paused }
}
struct StatusEpoch { func cancel() {} }
final class PackagingAttempt {
    let id = UUID()
    var isCurrent = true
    func cancel() { isCurrent = false }
}
@MainActor final class InstallJob {
    let id = UUID()
    let app: AppInfoPresentable
    enum Phase { case queued, running, completed, failed, skipped }
    var isTerminal: Bool { phase == .completed || phase == .failed || phase == .skipped }
    enum BatchRole { case none, pending, awaiting, host, member }
    // PRODUCTION_JOB_PHASE
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
    // PRODUCTION_SLOT_STATE
    // PRODUCTION_PACKAGING_TASK
    var _packagingAttempt: PackagingAttempt?
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

extension InstallSession {
    func sampleForegroundForTesting() { _recomputeProgress() }
}

@main struct InstallSessionControlsTests {
    @MainActor static func main() async throws {
        let session = InstallSession.shared
        let defaults = UserDefaults.standard
        let original = ["Feather.installationMethod", "Feather.serverMethod", "Feather.batchGroupSize", NativeInstallLimit.preferenceKey]
            .map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in original {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(2, forKey: "Feather.batchGroupSize")
        defaults.removeObject(forKey: NativeInstallLimit.preferenceKey)

        // Waiting apps are counted by events, never inspected by foreground
        // samples/header getters. Run the production phase observer as well as
        // the session so retries, removal and completion exercise both sides.
        defaults.set(1, forKey: "Feather.installationMethod")
        session.start(apps: (0..<1_000).map { TestApp(uuid: "static-\($0)") })
        ForegroundReadMetrics.reset()
        for _ in 0..<100 {
            session.sampleForegroundForTesting()
            precondition(session.waitingCount == 1_000 && session.runningCount == 0)
            precondition(!session.hasWorkInProgress && !session.hasInFlightGroup)
        }
        precondition(ForegroundReadMetrics.phases == 0 && ForegroundReadMetrics.progress == 0,
                     "Foreground refreshes must never revisit queued apps")

        let active = session.jobs[0]
        active.begin()
        active.viewModel.overallProgress = 0.6
        ForegroundReadMetrics.reset()
        for _ in 0..<100 {
            session.sampleForegroundForTesting()
            precondition(session.waitingCount == 999 && session.runningCount == 1)
            precondition(session.hasWorkInProgress)
        }
        precondition(ForegroundReadMetrics.progress == 100 && ForegroundReadMetrics.phases < 3_000,
                     "Only the one active app should contribute per-tick reads")
        precondition(abs(session.aggregateProgress - 0.6 / 1_000) < 1e-12)
        let removed = session.jobs.last!
        session.remove(removed)
        precondition(!session.containsJob(removed.id) && session.containsJob(active.id))
        session.sampleForegroundForTesting()
        precondition(session.waitingCount == 998 && session.totalCount == 999)
        precondition(abs(session.aggregateProgress - 0.6 / 999) < 1e-12)
        active.viewModel.overallProgress = 1
        active.deliver(.completed(.success(())))
        ForegroundReadMetrics.reset()
        for _ in 0..<100 { session.sampleForegroundForTesting() }
        precondition(ForegroundReadMetrics.phases == 0 && ForegroundReadMetrics.progress == 0,
                     "Settled progress should be retained without polling terminal apps")
        precondition(abs(session.aggregateProgress - 1.0 / 999) < 1e-12)

        let failed = session.jobs[1]
        failed.begin()
        failed.viewModel.overallProgress = 0.3
        failed.deliver(.completed(.failure(TestFailure.failed)))
        session.sampleForegroundForTesting()
        session.retry(failed)
        ForegroundReadMetrics.reset()
        for _ in 0..<100 { session.sampleForegroundForTesting() }
        precondition(ForegroundReadMetrics.phases == 0 && ForegroundReadMetrics.progress == 0)
        precondition(session.waitingCount == 998)
        precondition(abs(session.aggregateProgress - 1.3 / 999) < 1e-12,
                     "A queued retry retains its previous progress without further reads")
        failed.begin()
        failed.viewModel.overallProgress = 0.7
        session.sampleForegroundForTesting()
        precondition(abs(session.aggregateProgress - 1.7 / 999) < 1e-12,
                     "Starting a retry must replace its frozen progress, without double-counting")
        failed.deliver(.completed(.failure(TestFailure.failed)))
        session.start(apps: [failed.app])
        precondition(!session.containsJob(failed.id))
        failed.phase = .running // late callbacks from replaced jobs are ignored
        session.sampleForegroundForTesting()
        precondition(session.waitingCount == 998 && session.runningCount == 0)
        precondition(abs(session.aggregateProgress - 1.0 / 999) < 1e-12)
        session.dismissAll()
        session.sampleForegroundForTesting()
        precondition(session.waitingCount == 0 && !session.hasWorkInProgress)
        precondition(!session.containsJob(active.id))

        // The drawer/settings share a persistent setpoint. Changes apply to
        // the current native queue immediately, including while it is paused.
        precondition(NativeInstallLimit.savedValue == 5)
        defaults.set(2, forKey: NativeInstallLimit.preferenceKey)
        session.start(apps: [TestApp(uuid: "limit-two")])
        precondition(session.usesNativeInstallLimit && session.nativeInstallLimit == 2)
        precondition(InstallQueueCoordinator.shared.maxConcurrent == 2)
        session.setNativeInstallLimit(6)
        precondition(session.nativeInstallLimit == 6 && NativeInstallLimit.savedValue == 6)
        precondition(InstallQueueCoordinator.shared.maxConcurrent == 6)
        session.togglePause()
        session.setNativeInstallLimit(1)
        precondition(session.isPaused && InstallQueueCoordinator.shared.isPaused)
        precondition(InstallQueueCoordinator.shared.maxConcurrent == 1)
        session.start(apps: [TestApp(uuid: "same-queue")])
        precondition(InstallQueueCoordinator.shared.maxConcurrent == 1)
        session.dismissAll()
        precondition(!session.usesNativeInstallLimit)
        session.start(apps: [TestApp(uuid: "next-queue")])
        precondition(InstallQueueCoordinator.shared.maxConcurrent == 1)
        session.dismissAll()
        session.setNativeInstallLimit(101)
        precondition(session.nativeInstallLimit == 100 && NativeInstallLimit.savedValue == 100)
        session.start(apps: [TestApp(uuid: "limit-one-hundred")])
        precondition(InstallQueueCoordinator.shared.maxConcurrent == 100)
        session.dismissAll()

        // The native setpoint must never change server admission limits.
        defaults.set(0, forKey: "Feather.installationMethod")
        defaults.set(1, forKey: "Feather.serverMethod")
        session.start(apps: [TestApp(uuid: "server-limit")])
        precondition(!session.usesNativeInstallLimit && InstallQueueCoordinator.shared.maxConcurrent == 3)
        session.setNativeInstallLimit(0)
        precondition(session.nativeInstallLimit == 1 && NativeInstallLimit.savedValue == 1)
        precondition(InstallQueueCoordinator.shared.maxConcurrent == 3)
        session.dismissAll()
        defaults.removeObject(forKey: NativeInstallLimit.preferenceKey)

        // Same partial-batch workflow for native, local server, and external
        // server. Running jobs settle, queued jobs remain intact until cancel.
        for (method, server) in [(1, 0), (0, 0), (0, 1)] {
            defaults.set(method, forKey: "Feather.installationMethod")
            defaults.set(server, forKey: "Feather.serverMethod")
            session.start(apps: (0..<4).map { TestApp(uuid: "app\($0)") })
            precondition(InstallQueueCoordinator.shared.isNativeInstall == (method == 1))
            precondition(InstallQueueCoordinator.shared.maxConcurrent == (method == 1 || server == 0 ? 5 : 3),
                         "Native and local server batches must use five slots; external server remains at three")
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

        session.start(apps: [TestApp(uuid: "upload-finished")])
        let uploading = session.jobs[0]
        session.sampleForegroundForTesting()
        let unchangedPublications = PublicationMetrics.count
        for _ in 0..<100 { session.sampleForegroundForTesting() }
        precondition(PublicationMetrics.count == unchangedPublications,
                     "Unchanged progress/counters must not keep invalidating every session observer")
        uploading.begin()
        let beforeCountChange = PublicationMetrics.count
        session.sampleForegroundForTesting()
        precondition(PublicationMetrics.count > beforeCountChange && session.aggregateProgress == 0,
                     "Queued-to-running changes must refresh counters even before progress advances")
        InstallQueueCoordinator.shared.hasDeviceWorkInProgress = true
        uploading.viewModel.overallProgress = 2.0 / 3.0 // packaging/upload finished
        precondition(uploading._holdsSlot && InstallQueueCoordinator.shared.activeCount == 1,
                     "A finished upload must retain its shared slot during iOS installation")
        precondition(uploading.phase == .running && uploading.hasWorkInProgress,
                     "Finishing upload must not complete or hide the installation")
        session.togglePause()
        precondition(!session.canCancelAndSelectInstalled)
        uploading.deliver(.completed(.success(())))
        precondition(!session.canCancelAndSelectInstalled,
                     "Terminal status must still wait for native worker cleanup")
        InstallQueueCoordinator.shared.hasDeviceWorkInProgress = false
        session.cancelAndSelectInstalled()
        precondition(session.installedSelectionRequest?.appIDs == ["upload-finished"])
        session.consumeInstalledSelection(session.installedSelectionRequest!.id)

        session.start(apps: [TestApp(uuid: "never-started")])
        session.togglePause()
        InstallQueueCoordinator.shared.hasDeviceWorkInProgress = true
        precondition(!session.canCancelAndSelectInstalled,
                     "An installation still cleaning up must block selection even with no upload slots occupied")
        InstallQueueCoordinator.shared.hasDeviceWorkInProgress = false
        session.cancelAndSelectInstalled()
        precondition(session.installedSelectionRequest?.appIDs.isEmpty == true)
        precondition(!InstallQueueCoordinator.shared.isPaused && !session.isActive)
        // Local skips settle independently, preserve the remaining work and are
        // excluded from installed selection. Retrying a skip restores its count.
        defaults.set(1, forKey: "Feather.installationMethod")
        session.start(apps: [TestApp(uuid: "valid"), TestApp(uuid: "wrong-platform"), TestApp(uuid: "conflict")])
        let valid = session.jobs[0], wrong = session.jobs[1], conflict = session.jobs[2]
        for job in [valid, wrong, conflict] { job.begin() }
        wrong.deliver(.broken(IDeviceInstallSkip(reason: "tvOS app")))
        precondition(wrong.phase == .skipped && session.skippedCount == 1 && session.completedCount == 0)
        precondition(!session.isFinished && BackgroundTaskManager.shared.claimed)
        conflict.deliver(.broken(IDeviceInstallSkip(reason: "Installed identity conflict")))
        precondition(session.skippedCount == 2 && session.installedAppIDs.isEmpty)
        session.jobDidFinish(conflict)
        precondition(session.skippedCount == 2, "Repeated terminal delivery cannot double-count skips")
        valid.deliver(.completed(.success(())))
        precondition(session.isFinished && session.completedCount == 1 && session.skippedCount == 2)
        precondition(session.installedAppIDs == ["valid"])
        session.retry(wrong)
        precondition(!session.isFinished && session.skippedCount == 1 && wrong.phase == .queued)
        wrong.begin()
        wrong.deliver(.completed(.success(())))
        precondition(session.isFinished && session.completedCount == 2 && session.skippedCount == 1)
        session.remove(conflict)
        precondition(session.skippedCount == 0)
        session.cancelAndSelectInstalled()
        precondition(session.installedSelectionRequest?.appIDs == ["valid", "wrong-platform"])
        precondition(session.skippedCount == 0 && !BackgroundTaskManager.shared.claimed)
        print("Passed static 1,000-app queue, active-only foreground sampling, install pause/drain/cancel, skip accounting/retry, success tracking, retirement, and Signed selection scenarios")
    }
}

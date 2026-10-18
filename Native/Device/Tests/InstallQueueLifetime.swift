import Foundation
#if canImport(OSLog)
import OSLog
#else
func autoreleasepool<T>(invoking body: () throws -> T) rethrows -> T { try body() }
struct Logger {
    init(subsystem: String, category: String) {}
    func info(_ message: String) {}
    func warning(_ message: String) {}
    func notice(_ message: String) {}
    func critical(_ message: String) {}
}
final class DispatchSourceMemoryPressure {
    var data: DispatchSource.MemoryPressureEvent = []
    func setEventHandler(handler: @escaping () -> Void) {}
    func activate() {}
}
extension DispatchSource {
    struct MemoryPressureEvent: OptionSet {
        let rawValue: Int
        static let normal = Self(rawValue: 1)
        static let warning = Self(rawValue: 2)
        static let critical = Self(rawValue: 4)
        static let all: Self = [.normal, .warning, .critical]
    }
    static func makeMemoryPressureSource(eventMask: MemoryPressureEvent,
                                         queue: DispatchQueue) -> DispatchSourceMemoryPressure {
        DispatchSourceMemoryPressure()
    }
}
#endif

// Service doubles for the production coordinator. Memory admission and pressure
// handling remain in the compiled source; these supply a stable memory sample.
extension Logger { static let misc = Logger(subsystem: "KsignTests", category: "install") }
func os_proc_available_memory() -> UInt64 { 1_073_741_824 }
func _processPhysicalFootprintBytes() -> UInt64? { 134_217_728 }
func _availableProcessMemoryMB() -> UInt64 { 1024 }
final class ArchiveMemoryCoordinator {
    static let shared = ArchiveMemoryCoordinator()
    func setBuildCount(_ count: Int) {}
}
@MainActor final class InstallSession {
    struct Job { let id: UUID }
    static let shared = InstallSession()
    private var storedJobs: [Job] = []
    private var jobIDs: Set<UUID> = []
    var jobListReads = 0
    var jobs: [Job] {
        get { jobListReads += 1; return storedJobs }
        set { storedJobs = newValue; jobIDs = Set(newValue.map { $0.id }) }
    }
    func containsJob(_ id: UUID) -> Bool { jobIDs.contains(id) }
}

final class NativeWorkerBarrier {
    private let condition = NSCondition()
    private var arrived = 0
    func join() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        arrived += 1
        condition.broadcast()
        let deadline = Date().addingTimeInterval(3)
        while arrived < 2 {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }
}

@main struct InstallQueueLifetimeTests {
    @MainActor static func main() async throws {
        precondition(NativeInstallLimit.normalized(0) == 5)
        precondition(NativeInstallLimit.normalized(-1) == 1)
        precondition(NativeInstallLimit.normalized(2) == 2)
        precondition(NativeInstallLimit.normalized(100) == 100)
        precondition(NativeInstallLimit.normalized(101) == 100)
        precondition(NativeInstallLimit.enteredValue("") == nil)
        precondition(NativeInstallLimit.enteredValue("invalid") == nil)
        precondition(NativeInstallLimit.enteredValue(" 12 ") == 12)
        precondition(NativeInstallLimit.enteredValue("0") == 1)
        precondition(NativeInstallLimit.enteredValue("101") == 100)
        let barrier = NativeWorkerBarrier()
        async let workerA = IDeviceInstallationWorker.performInstallation { barrier.join() }
        async let workerB = IDeviceInstallationWorker.performInstallation { barrier.join() }
        let overlapped = try await (workerA, workerB)
        precondition(overlapped.0 && overlapped.1, "Native worker attempts must execute concurrently")

        let queue = InstallQueueCoordinator.shared

        // Native mode uses the real adaptive memory guard even at one. The
        // initial estimate must leave space for the app's existing footprint,
        // or one job plus its reserve incorrectly requires the entire budget.
        queue.setNativeInstallMode(true)
        queue.setMaxConcurrent(1)
        let serialIDs = (0..<2).map { _ in UUID() }
        InstallSession.shared.jobs = serialIDs.map { .init(id: $0) }
        var serialFirstStarted = false
        let serialFirst = Task { @MainActor in
            let acquired = await queue.acquire(for: serialIDs[0])
            serialFirstStarted = acquired
            return acquired
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(serialFirstStarted && queue.activeCount == 1,
                     "Native concurrency one must admit its first app with available memory")
        let serialFirstResult = await serialFirst.value
        precondition(serialFirstResult)
        queue.beginDeviceWork(serialIDs[0])
        var serialSecondStarted = false
        let serialSecond = Task { @MainActor in
            let acquired = await queue.acquire(for: serialIDs[1])
            serialSecondStarted = acquired
            return acquired
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(queue.activeCount == 1 && !serialSecondStarted)
        queue.release(serialIDs[0])
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(queue.activeCount == 1 && !serialSecondStarted,
                     "Serial native installs must wait for the previous worker's cleanup")
        queue.endDeviceWork(serialIDs[0])
        let serialSecondResult = await serialSecond.value
        precondition(serialSecondResult && queue.activeCount == 1)
        queue.beginDeviceWork(serialIDs[1])
        queue.endDeviceWork(serialIDs[1])
        queue.release(serialIDs[1])
        precondition(queue.activeCount == 0 && !queue.hasDeviceWorkInProgress)
        queue.setNativeInstallMode(false)

        queue.setMaxConcurrent(1)
        let first = UUID(), second = UUID()
        InstallSession.shared.jobs = [.init(id: first), .init(id: second)]
        let admitted = await queue.acquire(for: first)
        precondition(admitted)
        queue.beginDeviceWork(first)

        // Dismissing a row must neither release its native work nor let orphan
        // reclamation erase it when another job polls the queue.
        InstallSession.shared.jobs.removeFirst()
        queue.release(first)
        var secondStarted = false
        let waiting = Task { @MainActor in
            let acquired = await queue.acquire(for: second)
            secondStarted = acquired
            return acquired
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(queue.activeCount == 1 && !secondStarted,
                     "Cancelled native work must retain its slot until cleanup")
        queue.setPaused(true)
        queue.endDeviceWork(first)
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(queue.activeCount == 0 && !secondStarted,
                     "Paused queues must let active work finish without admitting a successor")
        queue.setPaused(false)
        let acquiredSecond = await waiting.value
        precondition(acquiredSecond && queue.activeCount == 1)

        // Successful native cleanup may precede the UI's completion delivery.
        // Keep the slot until that delivery asks to release it.
        queue.beginDeviceWork(second)
        queue.endDeviceWork(second)
        precondition(queue.activeCount == 1)
        queue.release(second)
        queue.release(second)
        precondition(queue.activeCount == 0)

        // Upload and iOS installation share one slot. A terminal UI callback
        // must still wait for the native worker's cleanup before admitting more.
        let uploading = UUID(), nextUpload = UUID()
        InstallSession.shared.jobs = [.init(id: uploading), .init(id: nextUpload)]
        let uploadSlot = await queue.acquire(for: uploading)
        precondition(uploadSlot)
        queue.beginDeviceWork(uploading)
        let readsBeforeWaiting = InstallSession.shared.jobListReads
        var eligibilityChecks = 0
        var nextStarted = false
        let next = Task { @MainActor in
            let acquired = await queue.acquire(for: nextUpload) {
                eligibilityChecks += 1
                return true
            }
            nextStarted = acquired
            return acquired
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(eligibilityChecks == 0 && InstallSession.shared.jobListReads == readsBeforeWaiting,
                     "Full native upload slots must not repeatedly scan the queued app list")
        queue.release(uploading)
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(queue.activeCount == 1 && queue.hasDeviceWorkInProgress && !nextStarted,
                     "Terminal delivery cannot free capacity before native cleanup")
        queue.endDeviceWork(uploading)
        let acquiredNext = await next.value
        precondition(acquiredNext && queue.activeCount == 1,
                     "The next app must start once the prior installation and cleanup finish")
        precondition(queue.activeCount == 1 && !queue.hasDeviceWorkInProgress,
                     "Finishing an old installation must not release its successor's upload slot")
        queue.release(nextUpload)

        // Cancellation of a waiter must not consume admission capacity.
        queue.setPaused(true)
        let cancelled = Task { @MainActor in await queue.acquire(for: nextUpload) }
        await Task.yield()
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        precondition(!cancelledResult && queue.activeCount == 0)
        queue.setPaused(false)

        // Native mode enforces five across upload and iOS installation. Keep
        // the real memory observation ramp in this test.
        queue.setNativeInstallMode(true)
        queue.setMaxConcurrent(NativeInstallLimit.defaultValue)
        let nativeIDs = (0..<6).map { _ in UUID() }
        InstallSession.shared.jobs = nativeIDs.map { .init(id: $0) }
        for id in nativeIDs.prefix(5) {
            let acquired = await queue.acquire(for: id)
            precondition(acquired)
            queue.beginDeviceWork(id)
        }
        var sixthAdmitted = false
        let sixth = Task { @MainActor in
            let acquired = await queue.acquire(for: nativeIDs[5])
            sixthAdmitted = acquired
            return acquired
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(queue.activeCount == 5 && !sixthAdmitted,
                     "A sixth native app must wait while five installations are active")
        // Worker cleanup can arrive before terminal UI delivery. Both must
        // finish before a shared slot can be reused.
        queue.endDeviceWork(nativeIDs[0])
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(queue.activeCount == 5 && !sixthAdmitted,
                     "Native worker completion must still await terminal UI release")
        queue.release(nativeIDs[0])
        let acquiredSixth = await sixth.value
        precondition(acquiredSixth && queue.activeCount == 5 && queue.hasDeviceWorkInProgress,
                     "A completed installation must admit the next app within the shared limit")
        precondition(queue.activeCount == 5,
                     "Old install cleanup must not release the next upload's slot")
        for id in nativeIDs.dropFirst() {
            queue.endDeviceWork(id)
            queue.release(id)
        }
        precondition(queue.activeCount == 0 && !queue.hasDeviceWorkInProgress)

        // Higher settings must permit more than five simultaneous apps while
        // preserving shared slots throughout each native worker's lifetime.
        queue.setMaxConcurrent(6)
        let higherLimitIDs = (0..<6).map { _ in UUID() }
        InstallSession.shared.jobs = higherLimitIDs.map { .init(id: $0) }
        for id in higherLimitIDs {
            let acquired = await queue.acquire(for: id)
            precondition(acquired)
            queue.beginDeviceWork(id)
        }
        precondition(queue.activeCount == 6,
                     "The configured limit must allow more than five active apps")

        let extraIDs = (0..<2).map { _ in UUID() }
        InstallSession.shared.jobs += extraIDs.map { .init(id: $0) }
        var afterLoweringStarted = false
        let afterLowering = Task { @MainActor in
            let acquired = await queue.acquire(for: extraIDs[0])
            afterLoweringStarted = acquired
            return acquired
        }
        queue.setMaxConcurrent(2)
        precondition(queue.activeCount == 6,
                     "Lowering the setpoint must leave every active app running")
        for id in higherLimitIDs.prefix(4) {
            queue.endDeviceWork(id)
            queue.release(id)
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(queue.activeCount == 2 && !afterLoweringStarted,
                     "No new app may start when the active count equals the lowered limit")
        // Even above the new limit, active workers retain their shared slots.
        queue.release(higherLimitIDs[4])
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(queue.activeCount == 2 && !afterLoweringStarted)
        queue.endDeviceWork(higherLimitIDs[4])
        let admittedAfterLowering = await afterLowering.value
        precondition(admittedAfterLowering && queue.activeCount == 2,
                     "Resume admissions only after the active count falls below the setpoint")

        var afterRaisingStarted = false
        let afterRaising = Task { @MainActor in
            let acquired = await queue.acquire(for: extraIDs[1])
            afterRaisingStarted = acquired
            return acquired
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(!afterRaisingStarted)
        queue.setPaused(true)
        queue.setMaxConcurrent(3)
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(queue.activeCount == 2 && !afterRaisingStarted,
                     "Raising the setpoint must not override pause")
        queue.setPaused(false)
        let admittedAfterRaising = await afterRaising.value
        precondition(admittedAfterRaising && queue.activeCount == 3,
                     "A raised setpoint must admit waiting work without another completion")
        queue.endDeviceWork(higherLimitIDs[5])
        queue.release(higherLimitIDs[5])
        for id in extraIDs { queue.release(id) }
        precondition(queue.activeCount == 0 && !queue.hasDeviceWorkInProgress)

        // A lower user-selected limit must cap the entire native lifecycle too.
        queue.setMaxConcurrent(2)
        let limitedIDs = (0..<3).map { _ in UUID() }
        InstallSession.shared.jobs = limitedIDs.map { .init(id: $0) }
        for id in limitedIDs.prefix(2) {
            let acquired = await queue.acquire(for: id)
            precondition(acquired)
            queue.beginDeviceWork(id)
        }
        var thirdStarted = false
        let third = Task { @MainActor in
            let acquired = await queue.acquire(for: limitedIDs[2])
            thirdStarted = acquired
            return acquired
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(queue.activeCount == 2 && !thirdStarted)
        queue.release(limitedIDs[0])
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(queue.activeCount == 2 && !thirdStarted,
                     "The configured limit must include terminal apps still cleaning up")
        queue.endDeviceWork(limitedIDs[0])
        let acquiredThird = await third.value
        precondition(acquiredThird && queue.activeCount == 2)
        // Reducing a running native queue to one must drain naturally and
        // continue serially, rather than getting stuck on the bootstrap guard.
        queue.setMaxConcurrent(1)
        let serialNextID = UUID()
        InstallSession.shared.jobs.append(.init(id: serialNextID))
        var serialNextStarted = false
        let serialNext = Task { @MainActor in
            let acquired = await queue.acquire(for: serialNextID)
            serialNextStarted = acquired
            return acquired
        }
        queue.endDeviceWork(limitedIDs[1])
        queue.release(limitedIDs[1])
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(queue.activeCount == 1 && !serialNextStarted,
                     "A live limit of one must wait until the current app finishes")
        queue.release(limitedIDs[2])
        let serialNextResult = await serialNext.value
        precondition(serialNextResult && queue.activeCount == 1,
                     "A queue lowered to one must continue admitting apps serially")
        queue.release(serialNextID)
        precondition(queue.activeCount == 0 && !queue.hasDeviceWorkInProgress)
        queue.setNativeInstallMode(false)
        queue.setMaxConcurrent(3)
        print("Passed native concurrency one startup/serial handoff/live reduction, configurable shared install ceiling, terminal/cleanup ordering, native queue cleanup and orphan-reclamation scenarios")
    }
}

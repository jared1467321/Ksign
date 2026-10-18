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
    var jobListReads = 0
    var jobs: [Job] {
        get { jobListReads += 1; return storedJobs }
        set { storedJobs = newValue }
    }
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
        let barrier = NativeWorkerBarrier()
        async let workerA = IDeviceInstallationWorker.performInstallation { barrier.join() }
        async let workerB = IDeviceInstallationWorker.performInstallation { barrier.join() }
        let overlapped = try await (workerA, workerB)
        precondition(overlapped.0 && overlapped.1, "Native worker attempts must execute concurrently")

        let queue = InstallQueueCoordinator.shared
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

        // Upload admission is separate from iOS's installation lifetime. The
        // first worker remains alive while its successor acquires upload space.
        let uploading = UUID(), nextUpload = UUID()
        InstallSession.shared.jobs = [.init(id: uploading), .init(id: nextUpload)]
        let uploadSlot = await queue.acquire(for: uploading)
        precondition(uploadSlot)
        queue.beginDeviceWork(uploading)
        let readsBeforeWaiting = InstallSession.shared.jobListReads
        var eligibilityChecks = 0
        let next = Task { @MainActor in
            await queue.acquire(for: nextUpload) {
                eligibilityChecks += 1
                return true
            }
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(eligibilityChecks == 0 && InstallSession.shared.jobListReads == readsBeforeWaiting,
                     "Full native upload slots must not repeatedly scan the queued app list")
        queue.finishDeviceUpload(uploading)
        precondition(queue.hasDeviceWorkInProgress,
                     "A free upload slot must not hide a live native installation worker")
        let acquiredNext = await next.value
        precondition(acquiredNext && queue.activeCount == 1,
                     "The next upload must start while iOS still installs the prior app")
        queue.endDeviceWork(uploading)
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

        // Native mode enforces five even if another caller configures a larger
        // ceiling. Keep the real memory observation ramp in this test.
        queue.setNativeInstallMode(true)
        queue.setMaxConcurrent(20)
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
                     "A sixth native upload must wait while five upload slots are occupied")
        queue.finishDeviceUpload(nativeIDs[0])
        let acquiredSixth = await sixth.value
        precondition(acquiredSixth && queue.activeCount == 5 && queue.hasDeviceWorkInProgress,
                     "A finished upload must free capacity while iOS installation remains alive")
        queue.endDeviceWork(nativeIDs[0])
        precondition(queue.activeCount == 5,
                     "Old install cleanup must not release the next upload's slot")
        for id in nativeIDs.dropFirst() {
            queue.endDeviceWork(id)
            queue.release(id)
        }
        precondition(queue.activeCount == 0 && !queue.hasDeviceWorkInProgress)
        queue.setNativeInstallMode(false)
        queue.setMaxConcurrent(3)
        print("Passed fixed five-upload ceiling, upload handoff, native queue cleanup and orphan-reclamation scenarios")
    }
}

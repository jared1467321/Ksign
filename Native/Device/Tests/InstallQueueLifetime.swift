import Foundation
import OSLog

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
    var jobs: [Job] = []
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
        print("Passed native queue cleanup and orphan-reclamation scenarios")
    }
}

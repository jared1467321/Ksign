import Foundation

// The runner instruments production orphan checks to count whole admission
// passes. The scheduling load must stay bounded as the waiting list grows.
enum AdmissionMetrics { static var passes = 0 }

@main struct InstallAdmissionLoadTests {
    @MainActor static func main() async throws {
        let queue = InstallQueueCoordinator.shared
        queue.setMaxConcurrent(1)
        let holder = UUID()
        let waitingIDs = (0..<1_000).map { _ in UUID() }
        InstallSession.shared.jobs = ([holder] + waitingIDs).map { .init(id: $0) }
        let initial = await queue.acquire(for: holder)
        precondition(initial)
        queue.beginDeviceWork(holder)
        AdmissionMetrics.passes = 0
        let waiting = waitingIDs.map { id in Task { @MainActor in await queue.acquire(for: id) } }
        try await Task.sleep(nanoseconds: 450_000_000)
        let passes = AdmissionMetrics.passes
        precondition((1...10).contains(passes),
                     "1,000 waiting apps must share one admission sampler; got \(passes) passes")
        for task in waiting { task.cancel() }
        for task in waiting {
            let acquired = await task.value
            precondition(!acquired, "Cancelled waiters must never claim upload capacity")
        }
        queue.endDeviceWork(holder)
        queue.release(holder)
        precondition(queue.activeCount == 0)

        // A cancelled waiter and a retry can share a job ID. An old cancellation
        // callback must only remove its own continuation, leaving the retry live.
        queue.setPaused(true)
        let retryID = waitingIDs[0]
        let old = Task { @MainActor in await queue.acquire(for: retryID) }
        await Task.yield()
        old.cancel()
        let retry = Task { @MainActor in await queue.acquire(for: retryID) }
        await Task.yield()
        queue.setPaused(false)
        let oldResult = await old.value
        let retryResult = await retry.value
        precondition(!oldResult && retryResult && queue.activeCount == 1)
        queue.release(retryID)

        // Eligibility still decides native selection/self-update order, even
        // when tasks register in a different order and spare slots exist.
        queue.setMaxConcurrent(3)
        let ids = Array(waitingIDs.prefix(4))
        var started: [Int] = []
        let ordered = [2, 0, 3, 1].map { index in Task { @MainActor in
            let acquired = await queue.acquire(for: ids[index]) {
                index == 0 || started.contains(index - 1)
            }
            precondition(acquired)
            started.append(index)
            queue.release(ids[index])
        } }
        for task in ordered { await task.value }
        precondition(started == [0, 1, 2, 3] && queue.activeCount == 0)
        print("Passed admission load: \(passes) shared passes for 1,000 waiting apps, bulk cancellation, retry isolation and eligibility order")
    }
}

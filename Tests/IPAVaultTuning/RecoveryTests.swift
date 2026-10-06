import Foundation

// Embed production cancellation and range accounting; only tasks and UI are mocked.
final class RecoveryTests {
    // ACTUAL_RECOVERY_CODE
    private final class Task {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    private final class IPAVaultJob {
        var tasks: [Int: Task] = [:]
        var freeRanges: [IPAVaultRange] = []
        var committedBytes: Int64 = 256
    }
    private var ipavaultTaskMetadata: [Int: IPAVaultTaskMetadata] = [:]
    private func updateIPAVaultProgress(for job: IPAVaultJob) {}

    func run() {
        let job = IPAVaultJob()
        let task = Task()
        let metadata = IPAVaultTaskMetadata(itemID: "file", leaseStart: 0,
            requestEnd: 1000, attempt: 0, startedAt: 0)
        metadata.committedEnd = 256
        metadata.currentPosition = 333
        job.tasks[1] = task
        ipavaultTaskMetadata[1] = metadata
        cancelIPAVaultStreams(job, requeueUnfinished: true, preserveReceivedBytes: true)
        assert(task.cancelled && job.tasks.isEmpty && ipavaultTaskMetadata.isEmpty)
        assert(job.committedBytes == 333)
        assert(job.freeRanges.count == 1)
        assert(job.freeRanges[0].start == 333 && job.freeRanges[0].end == 1000)
        assert(job.freeRanges[0].attempt == 0) // Recovery is not a failed range retry.
        cancelIPAVaultStreams(job, requeueUnfinished: true, preserveReceivedBytes: true)
        assert(job.committedBytes == 333 && job.freeRanges.count == 1)

        let finished = IPAVaultJob()
        let finishedTask = Task()
        let finishedMetadata = IPAVaultTaskMetadata(itemID: "file", leaseStart: 0,
            requestEnd: 1000, attempt: 0, startedAt: 0)
        finishedMetadata.committedEnd = 256
        finishedMetadata.currentPosition = 1000
        finished.tasks[2] = finishedTask
        ipavaultTaskMetadata[2] = finishedMetadata
        cancelIPAVaultStreams(finished, requeueUnfinished: true, preserveReceivedBytes: true)
        assert(finished.committedBytes == 1000 && finished.freeRanges.isEmpty)

        let ordinary = IPAVaultJob()
        let ordinaryMetadata = IPAVaultTaskMetadata(itemID: "file", leaseStart: 0,
            requestEnd: 1000, attempt: 0, startedAt: 0)
        ordinaryMetadata.committedEnd = 256
        ordinaryMetadata.currentPosition = 333
        ordinary.tasks[3] = Task()
        ipavaultTaskMetadata[3] = ordinaryMetadata
        cancelIPAVaultStreams(ordinary, requeueUnfinished: true)
        assert(ordinary.committedBytes == 256 && ordinary.freeRanges[0].start == 256)
        print("IPA Vault recovery tests passed")
    }
}
RecoveryTests().run()

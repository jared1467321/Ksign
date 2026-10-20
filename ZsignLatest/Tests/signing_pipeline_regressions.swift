import Foundation

private actor Latch {
    private var ready = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !ready { await withCheckedContinuation { waiting.append($0) } } }
    func open() { ready = true; let pending = waiting; waiting = []; pending.forEach { $0.resume() } }
}

private actor PipelineProbe {
    private var active: [String: Int] = [:]
    private var peak: [String: Int] = [:]
    private var overlapped = false
    func enter(_ stage: String) {
        active[stage, default: 0] += 1
        peak[stage] = max(peak[stage, default: 0], active[stage, default: 0])
        if active["signing", default: 0] > 0 && active["archive", default: 0] > 0 { overlapped = true }
    }
    func leave(_ stage: String) { active[stage, default: 0] -= 1 }
    func verify() {
        precondition(overlapped)
        precondition(peak["signing"] == 1 && peak["archive"] == 1)
        precondition(active.values.allSatisfy { $0 == 0 })
    }
}

@main struct SigningPipelineRegressions {
    enum Failure: Error { case expected }
    static func main() async throws {
        let signing = SigningStageGate(), archive = SigningStageGate()
        let archiveStarted = Latch(), secondSigning = Latch(), probe = PipelineProbe()
        let first = Task {
            await signing.run { await probe.enter("signing"); await probe.leave("signing") }
            await archive.run {
                await probe.enter("archive")
                await archiveStarted.open()
                await secondSigning.wait()
                await probe.leave("archive")
            }
        }
        await archiveStarted.wait()
        let second = Task {
            await signing.run {
                await probe.enter("signing")
                await secondSigning.open()
                await probe.leave("signing")
            }
            await archive.run { await probe.enter("archive"); await probe.leave("archive") }
        }
        await first.value; await second.value
        // Exercise queued admission and release when a stage throws.
        await withTaskGroup(of: Void.self) { tasks in
            for index in 0..<32 {
                tasks.addTask {
                    do {
                        try await signing.run {
                            await probe.enter("signing")
                            await Task.yield()
                            await probe.leave("signing")
                            if index % 3 == 0 { throw Failure.expected }
                        }
                    } catch Failure.expected {} catch { preconditionFailure("Unexpected error: \(error)") }
                }
            }
        }
        await probe.verify()
        print("Passed bounded signing/archive overlap, queued admission and failure release.")
    }
}

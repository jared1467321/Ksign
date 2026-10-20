import Foundation

#if os(Linux)
final class DispatchSourceMemoryPressure {
    var data: DispatchSource.MemoryPressureEvent = .normal
    func setEventHandler(handler: @escaping () -> Void) {}
    func activate() {}
    func cancel() {}
}
extension DispatchSource {
    struct MemoryPressureEvent: OptionSet {
        let rawValue: Int
        static let normal = Self(rawValue: 1)
        static let warning = Self(rawValue: 2)
        static let critical = Self(rawValue: 4)
        static let all: Self = [.normal, .warning, .critical]
    }
    static func makeMemoryPressureSource(eventMask: MemoryPressureEvent, queue: DispatchQueue) -> DispatchSourceMemoryPressure {
        DispatchSourceMemoryPressure()
    }
}
#endif
enum Logger {
    static let misc = Sink()
    struct Sink { func info(_ value: String) {} }
}

private final class Probe {
    private let lock = NSLock()
    private var time: TimeInterval = 10
    private var available: Double = 900
    private var footprint: Double = 100
    private var valid = true
    private var flag = false
    func snapshot() -> (footprint: Double, available: Double)? {
        lock.lock(); defer { lock.unlock() }
        return valid ? (footprint * 1_048_576, available * 1_048_576) : nil
    }
    func clock() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ delta: TimeInterval, available: Double? = nil, footprint: Double? = nil, valid: Bool? = nil) {
        lock.lock(); defer { lock.unlock() }
        time += delta
        if let available { self.available = available; self.footprint = 1000 - available }
        if let footprint { self.footprint = footprint }
        if let valid { self.valid = valid }
    }
    func setFlag() { lock.lock(); flag = true; lock.unlock() }
    func getFlag() -> Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

@main struct SigningMemoryRegressions {
    static func eventually(_ predicate: () -> Bool, file: StaticString = #file, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            precondition(Date() < deadline, "Timed out waiting for admission state", file: file, line: line)
            await Task.yield()
        }
    }
    private static func tick(_ memory: ArchiveMemoryCoordinator, _ probe: Probe, count: Int = 4) {
        for _ in 0..<count { probe.advance(0.1); memory.testSample() }
    }
    static func main() async throws {
        func setup() -> (ArchiveMemoryCoordinator, Probe) {
            let probe = Probe()
            let memory = ArchiveMemoryCoordinator(probe: probe.snapshot)
            memory.testClock(probe.clock)
            return (memory, probe)
        }
        func workload(_ bytes: Double = 4) -> ArchiveWorkload {
            ArchiveWorkload(operation: .signing, residentBytes: bytes * 1_048_576)
        }
        func start(_ memory: ArchiveMemoryCoordinator, _ work: ArchiveWorkload = ArchiveWorkload(operation: .signing), source: String? = nil) -> Task<ArchiveMemoryCoordinator.Lease, Error> {
            Task { try await memory.acquire(job: UUID(), attempt: UUID(), workload: work, source: source) }
        }

        // Reach the ceiling while the first job is still alive: no need to wait
        // for several complete apps to teach the controller before ramping up.
        let (memory, probe) = setup()
        var leases = [try await start(memory, workload()).value]
        for count in 2...ArchiveMemoryCoordinator.admissionCeiling {
            let pending = start(memory, workload())
            await eventually { memory.testState.queued == 1 }
            tick(memory, probe)
            await eventually { memory.testState.active == count }
            leases.append(try await pending.value)
        }
        precondition(probe.clock() < 12, "Healthy ramp should reach five jobs in under two seconds")
        let overflow = start(memory, workload())
        await eventually { memory.testState.queued == 1 }
        tick(memory, probe)
        precondition(memory.testState.active == ArchiveMemoryCoordinator.admissionCeiling)
        overflow.cancel()
        do { _ = try await overflow.value; preconditionFailure("Cancelled waiter must not get a lease") } catch is CancellationError {}
        precondition(memory.testState.active == leases.count, "Cancellation never releases a running native reservation")

        // Warning/critical stop admissions and hold younger jobs at phase
        // boundaries. The oldest worker can drain so pressure cannot deadlock.
        memory.testPressure(.warning)
        let held = start(memory, workload())
        await eventually { memory.testState.queued == 1 }
        tick(memory, probe)
        let waitingPhase = Task {
            try await memory.signingCheckpoint(leases[1], "before native signing")
            probe.setFlag()
        }
        for _ in 0..<100 { await Task.yield() }
        precondition(!probe.getFlag())
        try await memory.signingCheckpoint(leases[0], "oldest drains")
        memory.finish(leases.removeFirst(), succeeded: true)
        try await waitingPhase.value
        memory.testPressure(.critical)
        tick(memory, probe)
        precondition(memory.testState.queued == 1)
        memory.testPressure(.normal)
        tick(memory, probe)
        precondition(memory.testState.queued == 1, "Normal pressure still requires recovery cooldown")
        probe.advance(3.1); tick(memory, probe)
        await eventually { memory.testState.queued == 0 }
        leases.append(try await held.value)
        leases.forEach { memory.finish($0, succeeded: true) }
        precondition(memory.testState.active == 0 && memory.testState.queued == 0)

        let (low, lowProbe) = setup()
        let first = try await start(low, workload()).value
        let second = start(low, workload())
        await eventually { low.testState.queued == 1 }
        lowProbe.advance(0.1, available: 100); low.testSample()
        tick(low, lowProbe)
        precondition(low.testState.active == 1, "Low headroom blocks admission even without an iOS warning")
        lowProbe.advance(0.1, available: 900); tick(low, lowProbe)
        // Isolated growth is retained conservatively; finish it before retrying.
        low.finish(first, succeeded: false)
        tick(low, lowProbe, count: 20)
        let recovered = try await second.value
        low.finish(recovered, succeeded: true)

        let (trend, trendProbe) = setup()
        let growing = try await start(trend, workload()).value
        let afterGrowth = start(trend, workload())
        await eventually { trend.testState.queued == 1 }
        trendProbe.advance(0.1, available: 870); trend.testSample()
        tick(trend, trendProbe, count: 2)
        precondition(trend.testState.active == 1, "Falling headroom holds the ramp even with ample absolute memory")
        tick(trend, trendProbe, count: 5)
        await eventually { trend.testState.active == 2 }
        trend.finish(growing, succeeded: true)
        trend.finish(try await afterGrowth.value, succeeded: true)

        let (envelope, envelopeProbe) = setup()
        let existing = try await start(envelope, workload()).value
        let afterShrink = start(envelope, workload())
        await eventually { envelope.testState.queued == 1 }
        envelopeProbe.advance(0.1, available: 700, footprint: 100); envelope.testSample()
        tick(envelope, envelopeProbe)
        precondition(envelope.testState.active == 1, "A smaller process memory limit forces cooldown")
        envelopeProbe.advance(3.1); tick(envelope, envelopeProbe)
        await eventually { envelope.testState.active == 2 }
        envelope.finish(existing, succeeded: true)
        envelope.finish(try await afterShrink.value, succeeded: true)

        let (uiWarning, uiProbe) = setup()
        let uiExisting = try await start(uiWarning, workload()).value
        uiWarning.noteAppMemoryWarning()
        let afterWarning = start(uiWarning, workload())
        await eventually { uiWarning.testState.queued == 1 }
        tick(uiWarning, uiProbe)
        precondition(uiWarning.testState.active == 1, "UIKit warnings also stop signing admissions")
        uiProbe.advance(3.1); tick(uiWarning, uiProbe)
        await eventually { uiWarning.testState.active == 2 }
        uiWarning.finish(uiExisting, succeeded: true)
        uiWarning.finish(try await afterWarning.value, succeeded: true)

        let (duplicates, duplicatesProbe) = setup()
        let original = try await start(duplicates, workload(), source: "/same/Archive.ipa").value
        let duplicate = start(duplicates, workload(), source: "/same/Archive.ipa")
        await eventually { duplicates.testState.queued == 1 }
        tick(duplicates, duplicatesProbe)
        precondition(duplicates.testState.active == 1, "The same source cannot be signed/deleted concurrently")
        duplicates.finish(original, succeeded: true)
        let duplicateLease = try await duplicate.value
        duplicates.finish(duplicateLease, succeeded: true)

        let (unknown, unknownProbe) = setup()
        let known = try await start(unknown, workload()).value
        let unfamiliar = start(unknown, ArchiveWorkload(complete: false, operation: .signing))
        await eventually { unknown.testState.queued == 1 }
        tick(unknown, unknownProbe)
        precondition(unknown.testState.active == 1)
        unknown.finish(known, succeeded: true)
        let unfamiliarLease = try await unfamiliar.value
        unknown.finish(unfamiliarLease, succeeded: true)

        let (missing, missingProbe) = setup()
        missingProbe.advance(0, valid: false)
        let unavailable = start(missing, workload())
        await eventually { missing.testState.queued == 1 }
        tick(missing, missingProbe)
        precondition(missing.testState.active == 0)
        missingProbe.advance(0.1, valid: true); tick(missing, missingProbe)
        missing.finish(try await unavailable.value, succeeded: true)

        // Archive creation and signing must reserve against the same budget.
        let (shared, sharedProbe) = setup()
        let archive = start(shared, ArchiveWorkload())
        await eventually { shared.testState.queued == 1 }
        tick(shared, sharedProbe, count: 7)
        let archiveLease = try await archive.value
        let expensiveSigner = start(shared, workload(600))
        await eventually { shared.testState.queued == 1 }
        tick(shared, sharedProbe)
        precondition(shared.testState.active == 1, "Signing must include archive reservations in its admission")
        shared.finish(archiveLease, succeeded: false)
        shared.finish(try await expensiveSigner.value, succeeded: true)

        let (overlap, overlapProbe) = setup()
        let writer = start(overlap, ArchiveWorkload())
        await eventually { overlap.testState.queued == 1 }
        tick(overlap, overlapProbe, count: 7)
        let writerLease = try await writer.value
        let signer = start(overlap, workload())
        await eventually { overlap.testState.queued == 1 || overlap.testState.active == 2 }
        tick(overlap, overlapProbe)
        let signerLease = try await signer.value
        overlapProbe.advance(0.1, available: 300); overlap.testSample()
        overlap.finish(signerLease, succeeded: true)
        overlap.finish(writerLease, succeeded: true)
        overlapProbe.advance(2, available: 900); tick(overlap, overlapProbe)
        // Concurrent growth cannot be assigned to every operation and then
        // retained as a fictitious permanent per-archive allocation.
        overlap.finish(try await start(overlap, workload()).value, succeeded: true)
        print("Passed rapid live signing ramp, shared reservations, pressure/cooldown, cooperative draining, low headroom, duplicate sources, unknown workloads and cancellation.")
    }
}

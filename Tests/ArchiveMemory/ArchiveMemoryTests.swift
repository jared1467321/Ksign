import Foundation
import OSLog

extension Logger {
	static let misc = Logger(subsystem: "Ksign.ArchiveMemoryTests", category: "memory")
}

private let mib: Double = 1_048_576

private final class Telemetry: @unchecked Sendable {
	private let lock = NSLock()
	private var value: (footprint: Double, available: Double)? = (100 * mib, 900 * mib)
	func read() -> (footprint: Double, available: Double)? {
		lock.lock()
		defer { lock.unlock() }
		return value
	}
	func set(_ footprint: Double?, available: Double = 0) {
		lock.lock()
		value = footprint.map { ($0 * mib, available * mib) }
		lock.unlock()
	}
}

private struct Failure: Error { let message: String }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
	if !condition() { throw Failure(message: message) }
}
private func sleep(_ milliseconds: UInt64) async throws {
	try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
}
private func eventually(_ description: String, _ predicate: () -> Bool) async throws {
	let deadline = Date().addingTimeInterval(6)
	while !predicate() {
		if Date() > deadline { throw Failure(message: "Timed out: \(description)") }
		try await sleep(25)
	}
}
private func request(_ gate: ArchiveMemoryCoordinator, _ workload: ArchiveWorkload) -> Task<ArchiveMemoryCoordinator.Lease, Error> {
	Task {
		let lease = try await gate.acquire(job: UUID(), attempt: UUID(), workload: workload)
		gate.checkpoint(lease, "before native")
		return lease
	}
}
private func finish(_ gate: ArchiveMemoryCoordinator, _ lease: ArchiveMemoryCoordinator.Lease, success: Bool = true) async {
	gate.checkpoint(lease, "native returned")
	gate.checkpoint(lease, "temporary objects released")
	await gate.settle()
	gate.finish(lease, succeeded: success)
}
private func cancelled(_ task: Task<ArchiveMemoryCoordinator.Lease, Error>) async throws {
	task.cancel()
	do {
		_ = try await task.value
		throw Failure(message: "Cancelled waiter unexpectedly acquired a lease")
	} catch is CancellationError { }
}

@main
private struct ArchiveMemoryTests {
	static func main() async throws {
		// Also catches a regression that wedges acquire() itself.
		DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
			fatalError("Archive regression harness timed out")
		}
		let workload = ArchiveWorkload(entries: 100, pathBytes: 10_000, uncompressedBytes: 1_000_000)
		try await bootstrapAndLifetime(workload)
		try await missingAndInsufficientMemory(workload)
		try await reservationsAndEnvelopeChange(workload)
		try await pressureAndUnknownWorkload(workload)
		try await failureAndCancellation(workload)
		print("PASS: archive admission, lifetime peaks, reservations, ramp, telemetry failure, pressure recovery, unknown workloads and cancellation")
	}

	static func warm(_ gate: ArchiveMemoryCoordinator, _ workload: ArchiveWorkload) async throws {
		for _ in 0..<2 {
			let lease = try await request(gate, workload).value
			gate.checkpoint(lease, "before native")
			await finish(gate, lease)
		}
		try require(gate.testState.limit == 2, "Two completed safe observations should enable a measured ramp to two")
	}

	static func bootstrapAndLifetime(_ workload: ArchiveWorkload) async throws {
		let memory = Telemetry()
		let gate = ArchiveMemoryCoordinator(probe: memory.read)
		let first = try await request(gate, workload).value
		gate.checkpoint(first, "before native")
		let second = request(gate, workload)
		try await eventually("second queued") { gate.testState.queued == 1 }
		try await sleep(900) // Deliberately later than the old 0.8-second window.
		try require(gate.testState.active == 1, "Bootstrap must remain isolated")
		memory.set(140, available: 860)
		gate.checkpoint(first, "late peak")
		try require(gate.testState.reservations >= 60 * mib, "Reservation must cover observed late growth")
		memory.set(100, available: 900)
		await finish(gate, first)
		try require(gate.testState.peak >= 40 * mib, "Full-lifetime peak was not learned")
		let next = try await second.value
		gate.checkpoint(next, "before native")
		await finish(gate, next)
		try require(gate.testState.peak >= 40 * mib, "Cheap successor must not erase a high-water mark")
		try require(gate.testState.limit == 2, "Safe measured headroom should allow ramp-up")
		let a = try await request(gate, workload).value
		let b = try await request(gate, workload).value
		try require(gate.testState.active == 2, "Concurrency must not remain permanently one")
		try require(gate.testState.reservations >= 120 * mib, "Both active workers need full reservations")
		await finish(gate, a)
		await finish(gate, b)
		try require(gate.testState.active == 0, "Completed leases leaked")
	}

	static func missingAndInsufficientMemory(_ workload: ArchiveWorkload) async throws {
		let memory = Telemetry()
		memory.set(nil)
		let gate = ArchiveMemoryCoordinator(probe: memory.read)
		let missing = request(gate, workload)
		try await eventually("missing telemetry queued") { gate.testState.queued == 1 }
		try await sleep(200)
		try require(gate.testState.active == 0, "Telemetry failure must fail closed")
		try await cancelled(missing)
		try require(gate.testState.queued == 0, "Cancelled request leaked")
		memory.set(800, available: 200)
		let insufficient = request(gate, workload)
		try await sleep(800)
		try require(gate.testState.active == 0 && gate.testState.queued == 1, "Unsafe headroom should wait, not fail or admit")
		try await cancelled(insufficient)
	}

	static func pressureAndUnknownWorkload(_ workload: ArchiveWorkload) async throws {
		let memory = Telemetry()
		let gate = ArchiveMemoryCoordinator(probe: memory.read)
		try await warm(gate, workload)
		let running = try await request(gate, workload).value
		gate.testPressure(.warning)
		let waiting = request(gate, workload)
		try await eventually("pressure waiter") { gate.testState.queued == 1 }
		try await sleep(200)
		try require(gate.testState.active == 1 && gate.testState.limit == 1, "Pressure must stop new starts but retain the running lease")
		await finish(gate, running)
		gate.testPressure(.normal)
		try await sleep(600)
		try require(gate.testState.active == 0, "Normal pressure must not bypass recovery cooldown")
		let recovered = try await waiting.value
		try require(gate.testState.limit == 1, "Recovery must restart conservatively")
		await finish(gate, recovered)
		let second = try await request(gate, workload).value
		await finish(gate, second)
		try require(gate.testState.limit == 2, "Recovery must support a gradual ramp")

		let known = try await request(gate, workload).value
		var large = workload
		large.entries *= 10
		let unknown = request(gate, large)
		try await eventually("unknown workload queued") { gate.testState.queued == 1 }
		try await sleep(200)
		try require(gate.testState.active == 1, "Unfamiliar workload must wait for isolation")
		await finish(gate, known)
		let isolated = try await unknown.value
		let follower = request(gate, workload)
		try await eventually("follower queued") { gate.testState.queued == 1 }
		try await sleep(200)
		try require(gate.testState.active == 1, "Known request must not overlap an unmeasured active workload")
		try await cancelled(follower)
		await finish(gate, isolated)
	}

	static func reservationsAndEnvelopeChange(_ workload: ArchiveWorkload) async throws {
		let memory = Telemetry()
		let gate = ArchiveMemoryCoordinator(probe: memory.read)
		for _ in 0..<2 {
			let lease = try await request(gate, workload).value
			memory.set(200, available: 800)
			gate.checkpoint(lease, "measured peak")
			memory.set(100, available: 900)
			await finish(gate, lease)
		}
		try require(gate.testState.limit == 2, "Reservation scenario must permit concurrency by count")
		// New non-archive baseline: 500 MiB free fits candidate (150) + reserve
		// (250), but not the additional active reservation (150).
		memory.set(500, available: 500)
		let first = try await request(gate, workload).value
		let next = request(gate, workload)
		try await eventually("reservation waiter") { gate.testState.queued == 1 }
		try await sleep(200)
		try require(gate.testState.active == 1 && gate.testState.limit == 2, "Outstanding reservations must prevent over-admission")
		await finish(gate, first)
		let second = try await next.value
		await finish(gate, second)

		memory.set(100, available: 900)
		let running = try await request(gate, workload).value
		memory.set(100, available: 700) // Process envelope falls without footprint growth.
		gate.checkpoint(running, "process envelope shrank")
		try require(gate.testState.limit == 1, "Envelope shrink must reset concurrency")
		let waiting = request(gate, workload)
		try await eventually("envelope waiter") { gate.testState.queued == 1 }
		await finish(gate, running)
		try require(gate.testState.active == 0, "A smaller envelope must trigger cooldown")
		try await cancelled(waiting)
	}

	static func failureAndCancellation(_ workload: ArchiveWorkload) async throws {
		let memory = Telemetry()
		let gate = ArchiveMemoryCoordinator(probe: memory.read)
		let task = request(gate, workload)
		let lease = try await task.value
		task.cancel()
		try require(gate.testState.active == 1, "Cancellation after grant must not release the writer's lease")
		gate.checkpoint(lease, "before native")
		memory.set(nil)
		gate.checkpoint(lease, "telemetry lost during archive")
		memory.set(100, available: 900)
		await finish(gate, lease, success: false)
		try require(gate.testState.active == 0 && gate.testState.history == 0, "Failed/unreliable operation must release without training a safe workload")
		let successor = try await request(gate, workload).value
		gate.testPressure(.critical)
		let blocked = request(gate, workload)
		try await eventually("critical waiter") { gate.testState.queued == 1 }
		try await cancelled(blocked)
		await finish(gate, successor, success: false)
		try require(gate.testState.active == 0 && gate.testState.queued == 0, "Failure/cancellation must drain all leases and requests")
	}
}

import Foundation
import Darwin
import OSLog

// These are workload signals, not estimates of the device's physical RAM.
enum ArchiveOperation: Int, Sendable {
	case creation
	case miniZipExtraction
	case zipFoundationExtraction
}

struct ArchiveWorkload: Sendable {
	var entries: Double = 0
	var pathBytes: Double = 0
	var uncompressedBytes: Double = 0
	var compression: Int = 0
	var complete = true
	var operation: ArchiveOperation = .creation

	func covers(_ other: Self) -> Bool {
		complete && other.complete && operation == other.operation && compression == other.compression
			&& other.entries <= max(1, entries) * 1.5
			&& other.pathBytes <= max(1, pathBytes) * 1.5
			&& other.uncompressedBytes <= max(1, uncompressedBytes) * 2
	}

	// Central-directory growth temporarily keeps both the old and new buffers.
	// Include space for per-entry headers/extras, in addition to path bytes.
	var metadataAllowance: Double { 2 * (pathBytes + entries * 512) }
}

// Archive work can be synchronous. Cancellation withdraws a request, but never
// releases a running operation's reservation. Only its owner may finish the lease.
// All state and kernel callbacks live on this queue, independent of MainActor.
final class ArchiveMemoryCoordinator: @unchecked Sendable {
	static let shared = ArchiveMemoryCoordinator()
	static let admissionCeiling = 5

	struct Lease: Sendable { fileprivate let id: UUID }
	private struct Snapshot {
		let footprint: Double
		let available: Double
		var budget: Double { footprint + available }
	}
	private struct Request {
		let id: UUID
		let job: UUID
		let workload: ArchiveWorkload
	}
	private struct Observation {
		let request: Request
		let start: Snapshot
		var latest: Snapshot
		var peak: Double
		var minimum: Double
		var reservation: Double
		var isolated = true
		var reliable = true
		var pressured = false
		var nativeStarted = false
		var nativeReturned = false
		var cost: Double { max(0, peak - start.footprint, start.available - minimum) }
	}

	private let queue = DispatchQueue(
		label: "nya.asami.ksign.archive-memory", qos: .userInitiated, autoreleaseFrequency: .workItem
	)
	private var memoryProbe: () -> Snapshot? = ArchiveMemoryCoordinator.processSnapshot
	private var pressureSource: DispatchSourceMemoryPressure?
	private var timer: DispatchSourceTimer?
	private var waiting: [Request] = []
	private var active: [UUID: Observation] = [:]
	private var recent: [(time: TimeInterval, snapshot: Snapshot)] = []
	private var history: [ArchiveWorkload] = []
	private var learnedIsolatedPeak: Double = 0
	private var observedPeak: Double = 0
	private var concurrency = 1
	private var successfulObservations = 0
	private var pressure = "normal"
	private var recoveryUntil: TimeInterval = 0
	private var lastHold: [UUID: String] = [:]
	private var lastPeriodic: TimeInterval = 0
	private var buildCount = 0
	private let ceiling = ArchiveMemoryCoordinator.admissionCeiling
	private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

	private init(monitorPressure: Bool = true) {
		guard monitorPressure else { return }
		let source = DispatchSource.makeMemoryPressureSource(eventMask: .all, queue: queue)
		pressureSource = source
		source.setEventHandler { [weak self] in
			guard let self, let event = self.pressureSource?.data else { return }
			self.handlePressure(event)
		}
		source.activate()
	}

	deinit {
		timer?.cancel()
		pressureSource?.cancel()
	}

	private func handlePressure(_ event: DispatchSource.MemoryPressureEvent) {
		if event.contains(.critical) || event.contains(.warning) {
			self.pressure = event.contains(.critical) ? "critical" : "warning"
			self.concurrency = 1
			self.successfulObservations = 0
			self.recoveryUntil = .infinity
			for id in Array(self.active.keys) { self.active[id]?.pressured = true }
		} else if event.contains(.normal), self.pressure != "normal" {
			self.pressure = "normal"
			self.recoveryUntil = self.now + 3
			self.recent.removeAll()
		} else { return }
		self.lastHold.removeAll()
		self.log("pressure transition", snapshot: self.sample())
	}

	func setBuildCount(_ count: Int) {
		queue.async { self.buildCount = count }
	}

	func acquire(job: UUID, attempt: UUID, workload: ArchiveWorkload) async throws -> Lease {
		try Task.checkCancellation()
		let request = Request(id: attempt, job: job, workload: workload)
		queue.sync {
			precondition(!waiting.contains { $0.id == attempt } && active[attempt] == nil)
			waiting.append(request)
			startSampling()
		}
		// No continuation to race against cancellation or resume twice. The only
		// suspension is a cancellable sleep; the grant and reservation are atomic.
		defer {
			queue.sync {
				waiting.removeAll { $0.id == attempt }
				lastHold.removeValue(forKey: attempt)
				stopSamplingIfIdle()
			}
		}
		while true {
			try Task.checkCancellation()
			if queue.sync(execute: { admit(request) }) { return Lease(id: attempt) }
			try await Task.sleep(nanoseconds: 100_000_000)
		}
	}

	func checkpoint(_ lease: Lease, _ stage: String) {
		queue.sync {
			if stage == "before native" { active[lease.id]?.nativeStarted = true }
			if stage == "native returned" { active[lease.id]?.nativeReturned = true }
			log(stage, id: lease.id, snapshot: sample())
		}
	}

	// Observe after the writer and autorelease pool are gone. Cancellation must
	// NOT skip settling; the owner still cleans failed/cancelled output before
	// finish() relinquishes its reservation.
	func settle() async {
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			queue.asyncAfter(deadline: .now() + 0.5) { continuation.resume() }
		}
	}

	func finish(_ lease: Lease, succeeded: Bool) {
		queue.sync {
			let settled = self.sample()
			guard let observation = self.active.removeValue(forKey: lease.id) else {
				assertionFailure("Archive lease released twice")
				return
			}
			self.observedPeak = max(self.observedPeak, observation.cost)
			if observation.isolated && observation.reliable && observation.nativeStarted && observation.nativeReturned {
				// Never average away a dangerous high-water observation. Keeping
				// session high-water marks is intentionally conservative in v1.
				self.learnedIsolatedPeak = max(self.learnedIsolatedPeak, observation.cost)
				if succeeded && !observation.pressured && observation.request.workload.complete {
					self.history.removeAll { observation.request.workload.covers($0) }
					self.history.append(observation.request.workload)
					if self.history.count > 32 { self.history.removeFirst() }
				}
			}
			if succeeded && observation.reliable && !observation.pressured,
			   observation.nativeStarted && observation.nativeReturned,
			   !self.history.isEmpty, self.pressure == "normal", self.now >= self.recoveryUntil,
			   let settled, self.isStable,
			   settled.available > self.reservations + 2 * self.allowance(observation.request, settled) + self.reserve(settled) {
				self.successfulObservations += 1
				if self.successfulObservations >= 2 {
					self.concurrency = min(self.ceiling, self.concurrency + 1)
					self.successfulObservations = 0
				}
			} else {
				self.successfulObservations = 0
			}
			self.log("finished success=\(succeeded) isolated=\(observation.isolated) reliable=\(observation.reliable) startFootprint=\(self.mb(observation.start.footprint)) startAvailable=\(self.mb(observation.start.available)) peak=\(self.mb(observation.peak)) minimumAvailable=\(self.mb(observation.minimum)) finalFootprint=\(self.mb(observation.latest.footprint)) observedCost=\(self.mb(observation.cost))", id: lease.id, snapshot: settled, job: observation.request.job)
			self.stopSamplingIfIdle()
		}
	}

	private var reservations: Double { active.values.reduce(0) { $0 + $1.reservation } }
	private func allowance(_ request: Request, _ snapshot: Snapshot) -> Double {
		let bootstrap = history.isEmpty ? snapshot.budget / 6 : snapshot.budget * 0.03
		return max(bootstrap, 1.5 * max(learnedIsolatedPeak, observedPeak), request.workload.metadataAllowance)
	}
	private func reserve(_ snapshot: Snapshot) -> Double {
		let values = recent.map { $0.snapshot.available }
		let volatility = (values.max() ?? 0) - (values.min() ?? 0)
		return max(snapshot.budget * 0.25, 1.5 * observedPeak, 2 * volatility)
	}
	private var isStable: Bool {
		guard let first = recent.first, let last = recent.last,
		      last.time - first.time >= 0.5 else { return false }
		return first.snapshot.available - last.snapshot.available < last.snapshot.budget * 0.01
			&& first.snapshot.budget - last.snapshot.budget < last.snapshot.budget * 0.01
	}

	private func admit(_ request: Request) -> Bool {
		let snapshot = sample()
		var reason: String?
		if waiting.first?.id != request.id { reason = "FIFO predecessor" }
		else if pressure != "normal" { reason = "memory pressure" }
		else if now < recoveryUntil { reason = "recovery cooldown" }
		else if snapshot == nil { reason = "telemetry unavailable" }
		else if !isStable { reason = "headroom/envelope not settled" }
		else if active.count >= concurrency { reason = "conservative concurrency limit" }
		else if !active.isEmpty && (!history.contains { $0.covers(request.workload) }
			|| active.values.contains { observation in
				!history.contains { $0.covers(observation.request.workload) }
			}) {
			reason = "unfamiliar workload requires isolation"
		}
		if let snapshot, reason == nil,
		   snapshot.available <= allowance(request, snapshot) + reservations + reserve(snapshot) {
			reason = "candidate + active reservations + reserve exceed headroom"
		}
		if let reason {
			if lastHold[request.id] != reason {
				lastHold[request.id] = reason
				log("hold: \(reason)", id: request.id, snapshot: snapshot, candidate: snapshot.map { allowance(request, $0) } ?? 0, job: request.job)
			}
			return false
		}
		guard let snapshot else { return false }
		let cost = allowance(request, snapshot)
		let outstanding = reservations
		let isolated = active.isEmpty
		for id in Array(active.keys) { active[id]?.isolated = false }
		active[request.id] = Observation(request: request, start: snapshot, latest: snapshot,
			peak: snapshot.footprint, minimum: snapshot.available, reservation: cost, isolated: isolated)
		waiting.removeAll { $0.id == request.id }
		let mode = history.isEmpty ? "isolated bootstrap" :
			(history.contains { $0.covers(request.workload) } ? "measured headroom" : "isolated unfamiliar workload")
		log("admit: \(mode); priorReservations=\(mb(outstanding)); candidate + prior reservations + reserve fit", id: request.id, snapshot: snapshot, candidate: cost, job: request.job)
		return true
	}

	private static func processSnapshot() -> Snapshot? {
		var info = task_vm_info_data_t()
		var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
		let result = withUnsafeMutablePointer(to: &info) { pointer in
			pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
				task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
			}
		}
		guard result == KERN_SUCCESS else { return nil }
		return Snapshot(footprint: Double(info.phys_footprint), available: Double(os_proc_available_memory()))
	}

	private func sample() -> Snapshot? {
		guard let snapshot = memoryProbe(), snapshot.budget > 0 else {
			for id in Array(active.keys) { active[id]?.reliable = false }
			recent.removeAll()
			concurrency = 1
			successfulObservations = 0
			return nil
		}
		if let previous = recent.last?.snapshot, snapshot.budget < previous.budget * 0.95 {
			concurrency = 1
			successfulObservations = 0
			recoveryUntil = max(recoveryUntil, now + 3)
			for id in Array(active.keys) { active[id]?.pressured = true }
		}
		if now - (recent.last?.time ?? 0) >= 0.09 { recent.append((now, snapshot)) }
		recent.removeAll { $0.time < now - 1.5 }
		for id in Array(active.keys) {
			guard var observation = active[id] else { continue }
			observation.latest = snapshot
			observation.peak = max(observation.peak, snapshot.footprint)
			observation.minimum = min(observation.minimum, snapshot.available)
			observedPeak = max(observedPeak, observation.cost)
			observation.reservation = max(observation.reservation, observation.cost * 1.5)
			active[id] = observation
		}
		// A newly observed high-water mark applies to every outstanding worker,
		// including ones whose growth could be masked by another writer freeing
		// memory. Never shrink reservations when an archive makes progress.
		for id in Array(active.keys) {
			guard var observation = active[id] else { continue }
			observation.reservation = max(observation.reservation, observedPeak * 1.5)
			active[id] = observation
		}
		return snapshot
	}

	private func startSampling() {
		guard timer == nil else { return }
		recent.removeAll()
		let timer = DispatchSource.makeTimerSource(queue: queue)
		timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
		timer.setEventHandler { [weak self] in
			guard let self else { return }
			let snapshot = self.sample()
			if self.now - self.lastPeriodic >= 5 {
				self.lastPeriodic = self.now
				if self.active.isEmpty {
					self.log("periodic waiting", snapshot: snapshot)
				} else {
					for (id, observation) in self.active {
						self.log("periodic native=\(observation.nativeStarted && !observation.nativeReturned) peak=\(self.mb(observation.peak)) minimumAvailable=\(self.mb(observation.minimum))", id: id, snapshot: snapshot)
					}
				}
			}
		}
		self.timer = timer
		timer.activate()
	}
	private func stopSamplingIfIdle() {
		guard waiting.isEmpty && active.isEmpty else { return }
		timer?.cancel()
		timer = nil
		recent.removeAll()
	}
	private func mb(_ bytes: Double) -> Int { Int(bytes / 1_048_576) }
	private func log(_ reason: String, id: UUID? = nil, snapshot: Snapshot?, candidate: Double = 0, job: UUID? = nil) {
		let jobID = job ?? id.flatMap { active[$0]?.request.job }
		let message = "Archive gate \(reason); job=\(jobID?.uuidString ?? "-") attempt=\(id?.uuidString ?? "-") builds=\(buildCount) archives=\(active.count)/\(concurrency) queued=\(waiting.count) footprint=\(snapshot.map { mb($0.footprint) } ?? -1) available=\(snapshot.map { mb($0.available) } ?? -1) budget=\(snapshot.map { mb($0.budget) } ?? -1) candidate=\(mb(candidate)) learnedIsolated=\(mb(learnedIsolatedPeak)) observedPeak=\(mb(observedPeak)) reservations=\(mb(reservations)) reserve=\(snapshot.map { mb(reserve($0)) } ?? -1) pressure=\(pressure) recovering=\(now < recoveryUntil) [MiB]"
		Logger.misc.info("\(message, privacy: .public)")
	}

#if ARCHIVE_MEMORY_TESTING
	// Standalone regression harness uses the real queue/admission implementation
	// with synthetic telemetry, without UIKit or a physical memory-pressure event.
	convenience init(probe: @escaping () -> (footprint: Double, available: Double)?) {
		self.init(monitorPressure: false)
		memoryProbe = { probe().map { Snapshot(footprint: $0.footprint, available: $0.available) } }
	}

	func testPressure(_ event: DispatchSource.MemoryPressureEvent) {
		queue.sync { handlePressure(event) }
	}

	var testState: (active: Int, queued: Int, limit: Int, peak: Double, reservations: Double, history: Int) {
		queue.sync { (active.count, waiting.count, concurrency, learnedIsolatedPeak, reservations, history.count) }
	}
#endif

}

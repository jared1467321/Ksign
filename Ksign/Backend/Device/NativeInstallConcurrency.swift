import Foundation
import IDeviceSwift

// One bounded telemetry entry per admitted native job. Worker callbacks only
// update counters under a lock; the admission coordinator samples them itself.
final class NativeInstallUploadTelemetry {
    static let shared = NativeInstallUploadTelemetry()
    struct Snapshot {
        let bytes: UInt64
        let uploadingCount: Int
    }
    private let lock = NSLock()
    private var bytes: UInt64 = 0
    private var uploading: [UUID: UInt64] = [:]

    func record(_ event: IDeviceUploadEvent, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .started:
            uploading[id] = 0
        case .advanced(let sent):
            guard let previous = uploading[id], sent >= previous else { return }
            bytes &+= sent - previous
            uploading[id] = sent
        case .finished:
            uploading.removeValue(forKey: id)
        }
    }

    func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        uploading.removeValue(forKey: id)
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(bytes: bytes, uploadingCount: uploading.count)
    }
}

// Hill-climb aggregate useful upload bytes/second, not each app's individual
// rate. Trials change upload admission only: existing uploads always drain,
// and iOS installation lifetimes never occupy these upload slots.
// There is no fixed five-app ceiling; the queue and measured memory headroom
// bound growth. Timing windows avoid reacting to individual AFC writes.
struct NativeInstallConcurrencyTuner {
    private(set) var limit = 2
    private(set) var lastMeasuredBytesPerSecond: Double = 0
    private enum Phase {
        case baseline
        case trial(previous: Int, rate: Double, direction: Int)
        case steady(rate: Double, retryAt: TimeInterval, direction: Int)
    }
    private var phase: Phase = .baseline
    private var windowStart: (time: TimeInterval, bytes: UInt64)?
    private var settleUntil: TimeInterval = 0
    private var slowWindows = 0
    private let windowDuration: TimeInterval = 3
    private let settleDuration: TimeInterval = 1
    private let retryDelay: TimeInterval = 12

    mutating func suspend() {
        windowStart = nil
        slowWindows = 0
        phase = .baseline
    }

    mutating func update(now: TimeInterval, bytes: UInt64, activeJobs: Int,
                         queuedJobs: Int, uploadingCount: Int,
                         paused: Bool) {
        guard !paused, queuedJobs > 0, activeJobs > 0 else {
            windowStart = nil
            return
        }
        // Do not judge a trial until the requested count is actually running,
        // or while excess jobs are draining after a reduction. Memory admission
        // and connection preparation may delay reaching a new target.
        guard activeJobs == limit, uploadingCount == limit else {
            windowStart = nil
            return
        }
        guard now >= settleUntil else { return }
        guard let start = windowStart else {
            windowStart = (now, bytes)
            return
        }
        let elapsed = now - start.time
        guard elapsed >= windowDuration else { return }
        windowStart = (now, bytes)
        guard bytes >= start.bytes else { suspend(); return }
        let rate = Double(bytes - start.bytes) / elapsed
        // No useful transfer evidence cannot justify admitting more jobs.
        guard rate > 0 else { return }
        lastMeasuredBytesPerSecond = rate

        switch phase {
        case .baseline:
            beginTrial(direction: 1, rate: rate, now: now)
        case .trial(let previous, let baseline, let direction):
            let useful = direction > 0 ? rate > baseline * 1.05 : rate >= baseline * 0.97
            if useful {
                if direction > 0 {
                    // Continue searching while each extra job improves total
                    // throughput. Memory admission remains an independent gate.
                    beginTrial(direction: 1, rate: rate, now: now)
                } else {
                    phase = .steady(rate: rate, retryAt: now + retryDelay, direction: -1)
                }
            } else {
                changeLimit(previous, now: now)
                phase = .steady(rate: baseline, retryAt: now + retryDelay, direction: -direction)
            }
        case .steady(let baseline, let retryAt, let direction):
            slowWindows = rate < baseline * 0.78 ? slowWindows + 1 : 0
            if slowWindows >= 2 && limit > 1 {
                beginTrial(direction: -1, rate: rate, now: now)
            } else if now >= retryAt {
                beginTrial(direction: direction, rate: rate, now: now)
            }
        }
    }

    private mutating func beginTrial(direction: Int, rate: Double, now: TimeInterval) {
        let direction = limit == 1 ? 1 : direction
        let previous = limit
        changeLimit(max(1, limit + direction), now: now)
        phase = .trial(previous: previous, rate: rate, direction: direction)
        slowWindows = 0
    }

    private mutating func changeLimit(_ requested: Int, now: TimeInterval) {
        limit = max(1, requested)
        windowStart = nil
        settleUntil = now + settleDuration
    }
}

import Foundation

@main struct NativeUploadTuningTests {
    // Simulate saturated transfers with a monotonic clock. No wall-clock sleeps
    // or network timing: exercise the actual controller against link models.
    static func simulate(seconds: Int, rate: (Int, Double) -> Double) -> [Int] {
        var tuner = NativeInstallConcurrencyTuner()
        var bytes: UInt64 = 0
        var limits: [Int] = []
        for tick in 0..<(seconds * 4) {
            let now = Double(tick) / 4
            bytes += UInt64(rate(tuner.limit, now) * 0.25)
            tuner.update(now: now, bytes: bytes, activeJobs: tuner.limit,
                         queuedJobs: 100, uploadingCount: tuner.limit, paused: false)
            limits.append(tuner.limit)
        }
        return limits
    }

    static func main() {
        let mb = 1_048_576.0
        let scaling = simulate(seconds: 120) { count, _ in Double(min(count, 7)) * 10 * mb }
        precondition(scaling.max()! > 5, "Measured gains must permit more than five uploads")
        precondition(scaling.suffix(16).allSatisfy { (6...8).contains($0) },
                     "A saturated link must settle near its useful concurrency, not grow without evidence")

        let flat = simulate(seconds: 90) { _, _ in 20 * mb }
        precondition(flat.max()! <= 3 && flat.suffix(16).contains(1),
                     "Flat throughput must favor fewer competing uploads")
        let noisy = simulate(seconds: 90) { _, now in
            20 * mb * (1 + (Int(now * 4) % 2 == 0 ? 0.02 : -0.02))
        }
        precondition(noisy.max()! <= 3, "Small speed fluctuations must not cause runaway concurrency")

        let regression = simulate(seconds: 90) { count, _ in (count <= 2 ? 20 : 8) * mb }
        precondition(regression.max()! <= 3 && regression.suffix(16).allSatisfy { $0 <= 2 },
                     "An extra upload that reduces aggregate throughput must be rolled back")

        let changing = simulate(seconds: 220) { count, now in
            if now < 60 { return Double(min(count, 7)) * 10 * mb }
            return (count <= 2 ? Double(count) * 10 : 28 / Double(count - 1)) * mb
        }
        precondition(changing.prefix(240).max()! > 5)
        precondition(changing.suffix(40).allSatisfy { $0 <= 3 },
                     "Sustained link degradation must trigger fresh lower-concurrency trials")

        for scenario in 0..<5 {
            var tuner = NativeInstallConcurrencyTuner()
            for tick in 0..<200 {
                tuner.update(now: Double(tick), bytes: scenario == 4 ? 0 : UInt64(tick * 1_048_576),
                             activeJobs: scenario == 0 ? 1 : 2,
                             queuedJobs: scenario == 1 ? 0 : 100,
                             uploadingCount: scenario == 2 ? 0 : (scenario == 0 ? 1 : 2),
                             paused: scenario == 3)
            }
            precondition(tuner.limit == 2,
                         "Memory-held, drained, preparing, paused or stalled transfers must not cause growth")
        }

        let telemetry = NativeInstallUploadTelemetry()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let id = UUID()
            telemetry.record(.started, for: id)
            telemetry.record(.advanced(1_048_576), for: id)
            telemetry.record(.advanced(1_048_576), for: id) // duplicate
            telemetry.record(.advanced(1), for: id) // stale
            telemetry.record(.advanced(2_097_152), for: id)
            telemetry.record(.finished(success: true), for: id)
            telemetry.record(.advanced(3_145_728), for: id) // after finish
        }
        let snapshot = telemetry.snapshot()
        precondition(snapshot.bytes == 32 * 2_097_152 && snapshot.uploadingCount == 0,
                     "Concurrent telemetry must count only useful bytes and retire completed uploads")

        let mailbox = IDeviceInstallProgress()
        var deliveries = 0
        for index in 1...10_000 {
            if mailbox.submit(upload: Double(index) / 10_000) { deliveries += 1 }
        }
        precondition(deliveries == 1)
        precondition(mailbox.drain().upload == 1)
        precondition(!mailbox.submit(install: 0.5),
                     "A phase flush must not enqueue a second pending delivery")
        precondition(mailbox.drain(scheduled: true).install == 0.5)
        precondition(mailbox.submit(install: 1))
        precondition(mailbox.drain(finishing: true).install == 1)
        precondition(!mailbox.submit(upload: 0.2, install: 0.2))
        let stale = mailbox.drain(scheduled: true)
        precondition(stale.upload == nil && stale.install == nil,
                     "No stale progress may arrive after terminal delivery")
        print("Passed native upload scaling, saturation, regression, retuning, admission guards, telemetry and UI coalescing")
    }
}

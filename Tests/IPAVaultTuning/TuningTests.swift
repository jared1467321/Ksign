import Foundation

// The runner embeds the production probe evaluator, types, constants and search
// selection. Only transport and completion callbacks are replaced by stubs.
final class TuningTests {
    // ACTUAL_CONTROLLER_CODE
    private var ipavaultTotalUsefulBytes: Int64 = 0
    private var availableConcurrency = 8
    private var targetReached = true
    private var result: (keep: Bool, bps: Double)?
    private var ipavaultBatchProbe: IPAVaultBatchAdaptiveProbe?
    private var ipavaultBatchTargetStreams = 2
    private var ipavaultBatchStreamSearchCandidates: [Int] = []
    private var ipavaultBatchTestedStreams: Set<Int> = []

    private func availableIPAVaultBatchConcurrency() -> Int { availableConcurrency }
    private func ipavaultBatchProbeTargetReached(_ probe: IPAVaultBatchAdaptiveProbe) -> Bool { targetReached }
    private func finishIPAVaultConcurrencyTrialCandidate(measuredBPS: Double?, now: TimeInterval) {
        result = (measuredBPS != nil, measuredBPS ?? 0)
    }
    private func finishIPAVaultBatchProbe(_ probe: IPAVaultBatchAdaptiveProbe, keepTarget: Bool, measuredBPS: Double, now: TimeInterval) {
        result = (keepTarget, measuredBPS)
    }
    private func probe() -> IPAVaultBatchAdaptiveProbe {
        IPAVaultBatchAdaptiveProbe(dimension: .streams, previousValue: 2, targetValue: 4,
                                  baselineBPS: 100_000_000, noiseFraction: 0, requestedAt: 0)
    }
    private func begin(_ probe: IPAVaultBatchAdaptiveProbe) {
        result = nil
        continueIPAVaultBatchProbe(probe, now: 0)
        continueIPAVaultBatchProbe(probe, now: 0.5)
    }
    private func window(_ probe: IPAVaultBatchAdaptiveProbe, time: Double, bytes: Int64) {
        ipavaultTotalUsefulBytes += bytes
        continueIPAVaultBatchProbe(probe, now: time)
    }
    func run() {
        // Pre-probe bytes must never inflate the candidate measurement.
        ipavaultTotalUsefulBytes = 9_000_000_000
        let fast = probe()
        begin(fast)
        window(fast, time: 1, bytes: 60_000_000)
        assert(result == nil)
        window(fast, time: 1.5, bytes: 60_000_000)
        assert(result?.keep == true && result?.bps == 120_000_000)

        let slow = probe()
        begin(slow)
        window(slow, time: 1, bytes: 35_000_000)
        window(slow, time: 1.5, bytes: 35_000_000)
        assert(result?.keep == false && result?.bps == 70_000_000)

        // A close call uses the longer, bounded measurement path.
        let close = probe()
        begin(close)
        for tick in 1...4 {
            window(close, time: 0.5 + Double(tick) * 0.5, bytes: 52_500_000)
            assert(result == nil)
        }
        window(close, time: 3, bytes: 52_500_000)
        assert(result?.keep == true)

        // Alternating bursts do not justify an early decision.
        let noisy = probe()
        begin(noisy)
        for tick in 1...4 {
            window(noisy, time: 0.5 + Double(tick) * 0.5,
                   bytes: tick.isMultiple(of: 2) ? 70_000_000 : 40_000_000)
            assert(result == nil)
        }
        window(noisy, time: 3, bytes: 40_000_000)
        assert(result?.keep == false)

        // Zero-byte windows resolve a stall, rather than waiting for speed > 0.
        let stalled = probe()
        begin(stalled)
        window(stalled, time: 1, bytes: 0)
        window(stalled, time: 1.5, bytes: 0)
        assert(result?.keep == false && result?.bps == 0)

        let unavailable = probe()
        result = nil
        targetReached = false
        continueIPAVaultBatchProbe(unavailable, now: 4.25)
        assert(result?.keep == false)
        targetReached = true

        // Losing the requested configuration discards its partial measurement.
        let interrupted = probe()
        begin(interrupted)
        window(interrupted, time: 1, bytes: 60_000_000)
        targetReached = false
        continueIPAVaultBatchProbe(interrupted, now: 1.25)
        assert(interrupted.samples.isEmpty && interrupted.measuredBytes == 0)
        assert(interrupted.windowStartedAt == nil)
        targetReached = true

        ipavaultBatchStreamSearchCandidates = [2, 3, 3, 4]
        assert(nextIPAVaultStreamSearchTarget() == 3)
        assert(nextIPAVaultStreamSearchTarget() == 4)
        assert(nextIPAVaultStreamSearchTarget() == nil)
        print("IPA Vault tuning tests passed")
    }
}
TuningTests().run()

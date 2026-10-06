import Foundation

// The runner embeds the production probe evaluator, types, constants and search
// selection. Only transport and completion callbacks are replaced by stubs.
final class TuningTests {
    private func logIPAVault(_ message: String) {}
    // ACTUAL_CONTROLLER_CODE
    private var ipavaultTotalUsefulBytes: Int64 = 0
    private var availableConcurrency = 8
    private var targetReached = true
    private var workerStreamCount = 4
    private var tunerIPAVaultDrainInProgress = false
    private var runningIPAVaultDownloadCount: Int { measurementJobIDs.count }
    private var transferringIPAVaultDownloadCount: Int { targetReached ? measurementJobIDs.count : 0 }
    private var hasFreeRanges = true
    private struct Job { let tasks: [Int]; let freeRanges: [Int] }
    private func runningIPAVaultJobs() -> [Job] {
        measurementJobIDs.map { _ in Job(tasks: Array(0..<(targetReached ? workerStreamCount : 0)), freeRanges: hasFreeRanges ? [1] : []) }
    }
    private var ipavaultBatchTuningPhase: IPAVaultBatchTuningPhase = .streams
    private var ipavaultBatchLastStableBPS: Double = 0
    private var ipavaultBatchObservedCeilingBPS: Double = 0
    private var ipavaultBatchSpeedRiseStartedAt: TimeInterval?
    private var ipavaultBatchSpeedDropStartedAt: TimeInterval?
    private var ipavaultBatchRetuneAllowedAt: TimeInterval = 0
    private func updateIPAVaultAdaptivePresentation(status: String) {}
    private var measurementJobIDs: Set<String> = ["a", "b"]
    private var ipavaultBatchConfirmedBaseline: IPAVaultFreshMeasurement?
    private var ipavaultBatchControllerThroughputSamples: [(time: TimeInterval, bps: Double)] = []
    private var ipavaultBatchLastDecisionAt: TimeInterval = 0
    private var ipavaultBatchTargetConcurrency = 2
    private func currentIPAVaultMeasurementJobIDs() -> Set<String> { measurementJobIDs }
    private func setIPAVaultBatchStreams(_ streams: Int) { ipavaultBatchTargetStreams = streams }
    private func setIPAVaultBatchConcurrency(_ count: Int) { ipavaultBatchTargetConcurrency = count }
    private var result: (keep: Bool, bps: Double)?
    private var ipavaultBatchProbe: IPAVaultBatchAdaptiveProbe?
    private var ipavaultBatchTargetStreams = 2
    private var ipavaultBatchStreamSearchCandidates: [Int] = []
    private var ipavaultBatchTestedStreams: Set<Int> = []

    private func availableIPAVaultBatchConcurrency() -> Int { availableConcurrency }
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
        // An old peak must not become the speed reference for a new lock.
        ipavaultBatchObservedCeilingBPS = 50_000_000
        advanceIPAVaultTuningToSteady(now: 48, stableBPS: 32_000_000)
        assert(ipavaultBatchLastStableBPS == 32_000_000)
        assert(ipavaultBatchRetuneAllowedAt == 54)

        // Candidate measurements require the exact stream count, without draining bytes.
        let exact = probe()
        workerStreamCount = 5
        assert(!ipavaultBatchProbeTargetReached(exact))
        workerStreamCount = 4
        tunerIPAVaultDrainInProgress = true
        assert(!ipavaultBatchProbeTargetReached(exact))
        tunerIPAVaultDrainInProgress = false
        assert(ipavaultBatchProbeTargetReached(exact))

        workerStreamCount = 1
        hasFreeRanges = false
        assert(ipavaultBatchProbeTargetReached(exact)) // Normal end-of-file occupancy.
        hasFreeRanges = true
        assert(!ipavaultBatchProbeTargetReached(exact)) // Still can fill the missing slots.
        workerStreamCount = 4

        let evidence = IPAVaultConcurrencyTrial(previousConcurrency: 1, previousStreams: 2,
            previousBPS: 29_500_000, goalBPS: 29_500_000, targetConcurrency: 2,
            streamCandidates: [2, 1, 3])
        evidence.bestBPS = 24_100_000
        evidence.measuredCandidateCount = 1
        assert(!evidence.hasCompleteRegressionEvidence(toleranceFraction: 0.03))
        evidence.measuredCandidateCount = 3
        assert(!evidence.hasCompleteRegressionEvidence(toleranceFraction: 0.03)) // Noisy failures are insufficient.
        evidence.regressionCandidateCount = 3
        assert(evidence.hasCompleteRegressionEvidence(toleranceFraction: 0.03))
        evidence.bestBPS = 29_000_000
        assert(!evidence.hasCompleteRegressionEvidence(toleranceFraction: 0.03))

        let cached = IPAVaultFreshMeasurement(concurrency: 3, streams: 2,
            bps: 90_000_000, noise: 0.01, measuredAt: 10, jobIDs: ["a", "b", "c"])
        assert(cached.isValid(concurrency: 3, jobIDs: ["a", "b", "c"], now: 16))
        assert(!cached.isValid(concurrency: 3, jobIDs: ["a", "b", "c"], now: 16.01))
        assert(!cached.isValid(concurrency: 2, jobIDs: ["a", "b", "c"], now: 11))
        assert(!cached.isValid(concurrency: 3, jobIDs: ["a", "b", "d"], now: 11))
        assert(!cached.isValid(concurrency: 3, jobIDs: ["a", "b", "c"], now: 9))
        assert(cached.clearlyFails(threshold: 98_500_000, baselineBPS: 100_000_000))
        assert(!cached.clearlyFails(threshold: 91_000_000, baselineBPS: 100_000_000))
        let noisyCache = IPAVaultFreshMeasurement(concurrency: 3, streams: 2,
            bps: 90_000_000, noise: 0.15, measuredAt: 10, jobIDs: ["a", "b", "c"])
        assert(!noisyCache.clearlyFails(threshold: 98_500_000, baselineBPS: 100_000_000))

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
        assert(result?.keep == true) // Resolve bounded close calls from measured bytes.

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
        assert(result == nil && ipavaultBatchTargetStreams == unavailable.previousValue)
        targetReached = true

        // Brief slot replacement discards only the open window, not valid history.
        let interrupted = probe()
        begin(interrupted)
        window(interrupted, time: 1, bytes: 60_000_000)
        targetReached = false
        continueIPAVaultBatchProbe(interrupted, now: 1.25)
        assert(interrupted.samples.count == 1 && interrupted.measuredBytes == 60_000_000)
        assert(interrupted.windowStartedAt == nil)
        targetReached = true

        // A stream probe cannot compare a three-file baseline to a one-file tail.
        let shrinking = probe()
        shrinking.comparisonJobIDs = measurementJobIDs
        begin(shrinking)
        window(shrinking, time: 1, bytes: 60_000_000)
        measurementJobIDs = ["a"]
        availableConcurrency = 1
        continueIPAVaultBatchProbe(shrinking, now: 1.5)
        assert(result == nil && ipavaultBatchTargetStreams == shrinking.previousValue)
        measurementJobIDs = ["a", "b"]
        availableConcurrency = 8

        // File turnover at unchanged concurrency preserves a valid trial.
        let turnover = probe()
        begin(turnover)
        window(turnover, time: 1, bytes: 60_000_000)
        measurementJobIDs = ["a", "c"]
        continueIPAVaultBatchProbe(turnover, now: 1.25)
        assert(turnover.samples.count == 1 && turnover.measuredBytes == 60_000_000)
        assert(result == nil)
        window(turnover, time: 1.5, bytes: 60_000_000)
        assert(result?.keep == true)
        measurementJobIDs = ["a", "b"]

        // A brief replacement after four seconds is recoverable, not a zero-speed failure.
        let late = probe()
        begin(late)
        targetReached = false
        continueIPAVaultBatchProbe(late, now: 3.5)
        targetReached = true
        continueIPAVaultBatchProbe(late, now: 3.75)
        window(late, time: 4.25, bytes: 60_000_000)
        targetReached = false
        continueIPAVaultBatchProbe(late, now: 4.5)
        assert(result == nil && late.windowStartedAt == nil)
        targetReached = true
        continueIPAVaultBatchProbe(late, now: 4.75)
        window(late, time: 5.25, bytes: 60_000_000)
        window(late, time: 5.75, bytes: 60_000_000)
        window(late, time: 6.25, bytes: 60_000_000)
        assert(result?.keep == true)

        // Continual changes are bounded even if each individual interruption is brief.
        let bounded = probe()
        begin(bounded)
        continueIPAVaultBatchProbe(bounded, now: 8)
        assert(result == nil && ipavaultBatchTargetStreams == bounded.previousValue)

        // Capacity loss never creates a performance score.
        let capacity = IPAVaultBatchAdaptiveProbe(dimension: .streams, previousValue: 2,
            targetValue: 3, baselineBPS: 100_000_000, noiseFraction: 0,
            requestedAt: 0, requiredConcurrency: 3)
        result = nil
        availableConcurrency = 1
        continueIPAVaultBatchProbe(capacity, now: 0.5)
        assert(result == nil && ipavaultBatchTargetStreams == 2)
        availableConcurrency = 8

        workerStreamCount = 2
        // Replay the useful 2×2 windows discarded in the uploaded batch.
        let replay = IPAVaultBatchAdaptiveProbe(dimension: .streams, previousValue: 2,
            targetValue: 2, baselineBPS: 29_513_032, noiseFraction: 0, requestedAt: 0,
            concurrencyTrialCandidate: true, requiredConcurrency: 2)
        begin(replay)
        window(replay, time: 1, bytes: 24_914_678)
        targetReached = false
        continueIPAVaultBatchProbe(replay, now: 1.25)
        targetReached = true
        measurementJobIDs = ["c", "d"]
        continueIPAVaultBatchProbe(replay, now: 1.5)
        window(replay, time: 2, bytes: 16_109_422)
        // Burst variance may need the bounded path; add comparable windows.
        if result == nil {
            window(replay, time: 2.5, bytes: 20_000_000)
            window(replay, time: 3, bytes: 20_000_000)
            window(replay, time: 3.5, bytes: 20_000_000)
        }
        assert(result?.keep == true && result!.bps > 29_513_032)
        measurementJobIDs = ["a"]
        let fewer = IPAVaultBatchAdaptiveProbe(dimension: .concurrency, previousValue: 2,
            targetValue: 1, baselineBPS: 100_000_000, noiseFraction: 0, requestedAt: 0,
            requiredConcurrency: 1)
        begin(fewer)
        window(fewer, time: 1, bytes: 50_000_000)
        window(fewer, time: 1.5, bytes: 50_000_000)
        assert(result?.keep == false) // Equal speed cannot justify fewer files.
        measurementJobIDs = ["a", "b"]

        // Search ordering works for high stream counts too, without hard-coded winners.
        let candidates = ipavaultConcurrencyTrialStreamCandidates(previousConcurrency: 4,
            previousStreams: 8, targetConcurrency: 5)
        assert(candidates.first == 8 && candidates.count == 3)
        assert(Set(candidates).count == candidates.count)
        assert(candidates.allSatisfy { (1...10).contains($0) })

        ipavaultBatchStreamSearchCandidates = [2, 3, 3, 4]
        assert(nextIPAVaultStreamSearchTarget() == 3)
        assert(nextIPAVaultStreamSearchTarget() == 4)
        assert(nextIPAVaultStreamSearchTarget() == nil)
        print("IPA Vault tuning tests passed")
    }
}
TuningTests().run()

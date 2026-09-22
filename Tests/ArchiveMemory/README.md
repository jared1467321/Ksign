Run the standalone coordinator regression harness on macOS:

```sh
bash Tests/ArchiveMemory/run.sh
```

It compiles the production coordinator with synthetic, thread-safe process
telemetry and drives the actual queue, sampler, leases and pressure handling.
No iOS app build, signing identity, dependency fetch or physical memory pressure
is required. Test-only access is excluded from normal app builds.

Coverage includes delayed peaks after 0.8 seconds, conservative bootstrap,
high-water retention, measured parallelism, active reservations, missing/low
headroom, cancellation while queued and after grant, pressure cooldown,
unfamiliar workloads, and failed/unreliable observations. A 60-second watchdog
turns a stuck admission into a test failure.

This does not replace an Xcode app build or physical-device validation. Before
shipping, run repeated 2/5/10/20-app batches with large files and many-small-file
Payloads, all compression preferences, and foreground/background transitions.
Exercise retry/cancel during preparation, archive waiting, native archiving and
package handoff. Verify combined prompts, built-package retries, local/external
serving, idevice transfer, final progress and work-directory cleanup. Check
Instruments and jetsam reports; synthetic pressure alone cannot establish that
the process preserves sufficient real headroom.

Admission uses current process telemetry, a 25% envelope reserve (enlarged by
observed peaks/volatility), full reservations for existing archives, and a 50%
margin over observed peak growth. It starts at one archive and requires two
successful observations plus measured spare headroom per concurrency increase.
Unknown workloads run alone. Warning/critical pressure resets the ramp; normal
pressure requires a three-second cooldown and stable measurements. Telemetry
failure holds requests instead of reverting to unrestricted concurrency.

These are conservative initial policy choices to validate on devices, not
guarantees against an arbitrary process-limit reduction. A request that cannot
fit remains queued and cancellable; there is no timeout that fails the job or
silently spends the reserve. Peaks do not decay in this first implementation.

//
//  TempMaintenance.swift
//  Ksign
//
//  Keeps the temporary directory from accumulating abandoned work dirs
//  (FeatherSigning_*, FeatherInstall_*, half-built Archive.ipa, extracted
//  payloads).
//
//  Previously the only cleanup was a synchronous sweep on the main thread in
//  `didFinishLaunching`. Its cost grew with every batch — a frozen or
//  force-quit run left gigabytes behind — so deleting it all recursively on
//  the main thread eventually froze cold launches before the UI was even
//  interactive.
//
//  This does two things instead:
//    1. `cleanAtLaunch()` — the same "clear tmp" sweep, but off the main
//       thread, so launch never waits on it.
//    2. an idle sweep — runs shortly after the app goes quiet, so leftovers
//       are removed while nothing is using tmp, instead of piling up until
//       the next launch. It never runs while an import / sign / install is in
//       flight, and never touches anything written in the last few seconds.
//

import Foundation
import UIKit
import OSLog

@MainActor
final class TempMaintenance {
    static let shared = TempMaintenance()

    // Bumped around the two fire-and-forget FR pipelines (import + sign),
    // which stage their work under tmp. A counter, not a Bool, so overlapping
    // operations nest correctly — only the last one to finish frees things up.
    // The install path is covered by `InstallSession.isActive` and extraction
    // by `ExtractManager`, see `isBusy`.
    private var _activeOperations = 0

    // The pending debounced idle sweep. Cancelled the instant new work starts
    // or another sweep is scheduled, so it only ever fires once things settle.
    private var _idleSweep: Task<Void, Never>?

    // Never delete anything written this recently, even when we believe we're
    // idle. Pure safety margin against a busy signal we didn't account for.
    private let _minIdleAge: TimeInterval = 30

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(_appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    // MARK: - Busy tracking

    // The single source of truth for "is it safe to delete tmp?". Deliberately
    // reads live state rather than trusting a flag to be toggled correctly.
    var isBusy: Bool {
        _activeOperations > 0
            || InstallSession.shared.isActive
            || !ExtractManager.shared.extractItems.isEmpty
    }

    // Call at the start of any pipeline that writes to tmp; pair with
    // `endOperation()` when it finishes (success *or* failure).
    func beginOperation() {
        _activeOperations += 1
        _idleSweep?.cancel()
        _idleSweep = nil
    }

    func endOperation() {
        _activeOperations = max(0, _activeOperations - 1)
        _scheduleIdleSweep()
    }

    // MARK: - Launch sweep (non-blocking)

    // Called from `didFinishLaunching`. At cold launch nothing is in flight, so
    // everything currently in tmp is stale and safe to remove. The listing and
    // the deletes both run off the main thread, so launch never blocks on it.
    func cleanAtLaunch() {
        let tmp = FileManager.default.temporaryDirectory
        Task.detached(priority: .utility) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: tmp,
                includingPropertiesForKeys: nil
            ) else { return }

            var removed = 0
            for url in entries {
                do { try FileManager.default.removeItem(at: url); removed += 1 }
                catch { /* best-effort */ }
            }
            if removed > 0 {
                Logger.misc.info("Launch tmp sweep removed \(removed) item(s)")
            }
        }
    }

    // MARK: - Idle sweep

    @objc private nonisolated func _appDidBecomeActive() {
        Task { @MainActor in self._scheduleIdleSweep() }
    }

    private func _scheduleIdleSweep() {
        _idleSweep?.cancel()
        // Task created in a @MainActor context inherits main-actor isolation,
        // so the `isBusy` read below is race-free.
        _idleSweep = Task { [weak self] in
            // Wait for the app to stay quiet. If new work starts,
            // `beginOperation()` cancels this before it fires.
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, !self.isBusy else { return }
            await self._sweepOrphans(minAge: self._minIdleAge)
        }
    }

    // Deletes tmp entries not modified within `minAge`. Only ever called when
    // idle; the age check is a second line of defence so a just-created work
    // dir is never removed out from under an operation we somehow didn't count.
    private func _sweepOrphans(minAge: TimeInterval) async {
        let tmp = FileManager.default.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-minAge)

        await Task.detached(priority: .utility) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: tmp,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { return }

            var removed = 0
            for url in entries {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                guard modified < cutoff else { continue }
                do { try FileManager.default.removeItem(at: url); removed += 1 }
                catch { /* best-effort */ }
            }
            if removed > 0 {
                Logger.misc.info("Idle tmp sweep removed \(removed) item(s)")
            }
        }.value
    }
}

// Concatenated with production source so this extension can exercise private
// transitions without exposing a testing API in the app.
extension BackgroundTaskManager {
    private func drainRecovery() {
        for _ in 0..<10 {
            _submissionQueue.sync {}
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    private func launch(_ owner: Owner) -> BGContinuedProcessingTask {
        _submissionQueue.sync {}
        let task = BGContinuedProcessingTask()
        _workflowDidLaunch(owner, identifier: _workflowStates[owner]!.identifier!, task: task)
        return task
    }

    static func runRecoveryTests() {
        let manager = BackgroundTaskManager()
        let owners: [Owner] = [.bulkInstalls, .singleInstall, .bulkExport, .importing,
                               .signing, .extracting, .ipaVaultDownloads]
        for owner in owners {
            manager.claim(owner)
            manager.report(owner, completed: 2, total: 5, fraction: nil,
                           detail: "Working", currentItem: "Example.ipa")
            let first = manager.launch(owner)
            let staleExpiration = first.expirationHandler!
            UIApplication.shared.applicationState = .background
            staleExpiration()
            manager.drainRecovery()
            assert(manager._workflowStates[owner]!.success)
            assert(manager._workflowStates[owner]!.task == nil)
            assert(first.completions == [false]) // Expired lease, not failed batch.

            UIApplication.shared.applicationState = .active
            NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            manager.drainRecovery()
            let second = manager.launch(owner)
            assert(second.progress.fractionCompleted == 0.4)
            assert(second.subtitle.contains("Example.ipa"))
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            manager.drainRecovery()
            assert(manager._workflowStates[owner]!.task === second)
            assert(second.completions.isEmpty) // No renewal for a permission prompt alone.
            staleExpiration()
            assert(manager._workflowStates[owner]!.task === second)

            // Missing UI without an expiration callback leaves this reference
            // non-nil. Foreground renewal must replace it anyway.
            manager._recoverActiveTasks(renewLeases: true)
            manager.drainRecovery()
            assert(second.completions == [true])
            let third = manager.launch(owner)
            assert(third.progress.fractionCompleted == 0.4)
            manager._apply(owner: owner, report: manager._workflowStates[owner]!.report, to: second)
            manager._completeTask(second, success: false) // Late duplicate is ignored.
            assert(second.completions == [true])
            manager.release(owner)
            assert(third.completions == [true])
        }

        // A late finish must not remove a new/remaining counted worker.
        manager.begin(.signing)
        let signing = manager.launch(.signing)
        manager._finishWorkflow(.signing)
        assert(manager._workflowStates[.signing]!.count == 1)
        assert(signing.completions.isEmpty)
        manager.report(.signing, detail: "Error") // Presentation is not a terminal result.
        manager.end(.signing, success: true)
        assert(signing.completions == [true])

        // Actual failures survive renewal and still produce a failed final result.
        manager.claim(.importing)
        manager.begin(.importing)
        manager.end(.importing, success: false)
        manager._recoverActiveTasks(renewLeases: true)
        manager.drainRecovery()
        let importing = manager.launch(.importing)
        manager.release(.importing)
        assert(importing.completions == [false])

        // Queued requests with no launch are replaced; late launches are rejected.
        manager.claim(.bulkInstalls)
        manager._submissionQueue.sync {}
        let oldID = manager._workflowStates[.bulkInstalls]!.identifier!
        manager._recoverActiveTasks(renewLeases: true)
        manager.drainRecovery()
        assert(!BGTaskScheduler.shared.contains(oldID))
        assert(manager._workflowStates[.bulkInstalls]!.identifier != oldID)
        let late = BGContinuedProcessingTask()
        manager._workflowDidLaunch(.bulkInstalls, identifier: oldID, task: late)
        assert(late.completions == [false])
        manager.release(.bulkInstalls)

        BGTaskScheduler.shared.rejectSubmission = true
        manager.claim(.extracting)
        manager._submissionQueue.sync {}
        assert(!manager._workflowStates[.extracting]!.requestOutstanding)
        BGTaskScheduler.shared.rejectSubmission = false
        manager._recoverActiveTasks()
        manager.drainRecovery()
        assert(manager._workflowStates[.extracting]!.requestOutstanding)
        manager.release(.extracting)

        UIApplication.shared.applicationState = .background
        manager.claim(.bulkExport)
        manager._submissionQueue.sync {}
        assert(!manager._workflowStates[.bulkExport]!.requestOutstanding)
        UIApplication.shared.applicationState = .active
        manager._recoverActiveTasks()
        manager.drainRecovery()
        let export = manager.launch(.bulkExport)
        manager.release(.bulkExport)
        assert(export.completions == [true])

        // Regular downloads keep running/reporting through lease expiration.
        manager.startTask(for: "a", filename: "A.ipa")
        manager.startTask(for: "b", filename: "B.ipa")
        manager._submissionQueue.sync {}
        let download = BGContinuedProcessingTask()
        manager._downloadDidLaunch(identifier: manager._downloadBatchState!.identifier!, task: download)
        manager.updateProgress(for: "a", progress: 0.5)
        download.expirationHandler!()
        manager.drainRecovery()
        assert(manager._downloadBatchState!.success)
        assert(!manager._downloadBatchState!.items["a"]!.terminal)
        let replacement = BGContinuedProcessingTask()
        manager._downloadDidLaunch(identifier: manager._downloadBatchState!.identifier!, task: replacement)
        assert(replacement.progress.fractionCompleted == 0.25)
        manager.stopTask(for: "a", success: true)
        assert(replacement.completions.isEmpty)
        manager.stopTask(for: "b", success: true)
        assert(replacement.completions == [true])
        manager._recoverActiveTasks(renewLeases: true)
        manager.drainRecovery()
        assert(manager._workflowStates.isEmpty && manager._downloadBatchState == nil)
        print("Background task recovery tests passed")
    }
}

@main enum RecoveryTests {
    static func main() { BackgroundTaskManager.runRecoveryTests() }
}

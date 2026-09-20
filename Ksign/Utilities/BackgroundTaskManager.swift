//
//  BackgroundTaskManager.swift
//  Ksign
//
//  Owns BGContinuedProcessingTask-backed execution and system Live Activity
//  progress for every long-running workflow in the app.
//

import BackgroundTasks
import Foundation

final class BackgroundTaskManager: ObservableObject {
    static let shared = BackgroundTaskManager()

    enum Owner: String {
        case bulkInstalls
        case singleInstall
        case bulkExport
        case importing
        case signing
        case extracting
        case ipaVaultDownloads

        var title: String {
            switch self {
            case .bulkInstalls:       return "Installing Apps"
            case .singleInstall:      return "Installing App"
            case .bulkExport:         return "Exporting Apps"
            case .importing:          return "Importing Apps"
            case .signing:            return "Signing Apps"
            case .extracting:         return "Extracting"
            case .ipaVaultDownloads:  return "IPA Vault Downloads"
            }
        }
    }

    private struct Report: Equatable {
        var completed: Int?
        var total: Int?
        var fraction: Double?
        var detail: String?
    }

    private struct WorkflowState {
        var task: BGContinuedProcessingTask?
        var identifier: String?
        var handlerRegistered = false
        var requestOutstanding = false
        var submissionToken: UUID?
        var identityClaimed = false
        var count = 0
        var success = true
        var suppressed = false
        var report = Report()
    }

    private struct DownloadState {
        var task: BGContinuedProcessingTask?
        var identifier: String?
        var handlerRegistered = false
        var requestOutstanding = false
        var submissionToken: UUID?
        var title: String
        var subtitle: String
        var progress: Double = 0
        var suppressed = false
    }

    private let _lock = NSLock()
    private let _submissionQueue = DispatchQueue(
        label: "AppAssassin.signer.ipa.background-task-submission",
        qos: .userInitiated
    )
    private var _workflowStates: [Owner: WorkflowState] = [:]
    private var _downloadStates: [String: DownloadState] = [:]

    // Keep fraction-backed Progress granular enough that long jobs visibly move
    // even when each callback advances by much less than one percent.
    private static let _fractionProgressUnits: Int64 = 1_000_000

    private let _baseIdentifier: String

    private init() {
        let bundleID = Bundle.main.bundleIdentifier ?? "AppAssassin.signer.ipa"
        _baseIdentifier = "\(bundleID).userTask"
    }

    // MARK: - Workflow ownership

    // Identity ownership is useful for a batch/queue whose individual workers
    // can briefly drop to zero. Repeated claims from the same owner are idempotent.
    func claim(_ owner: Owner) {
        _lock.lock()
        var state = _workflowStates[owner] ?? WorkflowState()
        let wasClaimed = state.identityClaimed
        state.identityClaimed = true
        if !wasClaimed && state.count == 0 {
            state.success = true
            state.suppressed = false
        }
        _workflowStates[owner] = state
        _lock.unlock()

        BackgroundAudioManager.shared.claimSystemTask(_audioKey(for: owner))
        _submitWorkflowIfNeeded(owner)
    }

    func release(_ owner: Owner, success: Bool = true) {
        var shouldFinish = false

        _lock.lock()
        guard var state = _workflowStates[owner] else {
            _lock.unlock()
            return
        }
        state.identityClaimed = false
        state.success = state.success && success
        shouldFinish = state.count == 0
        _workflowStates[owner] = state
        _lock.unlock()

        if shouldFinish {
            _finishWorkflow(owner)
        }
    }

    // Counted ownership protects overlapping workers of the same operation type.
    func begin(_ owner: Owner) {
        _lock.lock()
        var state = _workflowStates[owner] ?? WorkflowState()
        if state.count == 0 && !state.identityClaimed {
            state.success = true
            state.suppressed = false
        }
        state.count += 1
        _workflowStates[owner] = state
        _lock.unlock()

        BackgroundAudioManager.shared.claimSystemTask(_audioKey(for: owner))
        _submitWorkflowIfNeeded(owner)
    }

    func end(_ owner: Owner, success: Bool) {
        var shouldFinish = false

        _lock.lock()
        guard var state = _workflowStates[owner], state.count > 0 else {
            _lock.unlock()
            return
        }
        state.count -= 1
        state.success = state.success && success
        shouldFinish = state.count == 0 && !state.identityClaimed
        _workflowStates[owner] = state
        _lock.unlock()

        if shouldFinish {
            _finishWorkflow(owner)
        }
    }

    // MARK: - Workflow progress

    // This mirrors the old Live Activity reporting surface so each existing
    // reporter still decides which changes are meaningful. Identical snapshots
    // are discarded before BackgroundTasks sees them.
    func report(
        _ owner: Owner,
        completed: Int?,
        total: Int?,
        fraction: Double?,
        detail: String?
    ) {
        let normalizedDetail: String? = {
            let value = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }()
        let normalizedFraction = fraction.map { min(1, max(0, $0)) }

        var task: BGContinuedProcessingTask?
        var reportToApply: Report?

        _lock.lock()
        var state = _workflowStates[owner] ?? WorkflowState()
        let next = Report(
            completed: {
                guard let total, total > 0, let completed else { return nil }
                return max(0, min(completed, total))
            }(),
            total: {
                guard let total, total > 0, completed != nil else { return nil }
                return total
            }(),
            fraction: normalizedFraction,
            detail: normalizedDetail
        )

        if state.report != next {
            state.report = next
            if normalizedDetail == "Error" || normalizedDetail == "Cancelled" {
                state.success = false
            }
            task = state.task
            reportToApply = next
        }
        _workflowStates[owner] = state
        _lock.unlock()

        if let task, let reportToApply {
            _apply(owner: owner, report: reportToApply, to: task)
        }

        // A report is state, not ownership. Only `claim` / `begin` may create a
        // task, so a late asynchronous reporter can never resurrect a finished
        // system Live Activity.
    }

    func report(_ owner: Owner, completed: Int, total: Int?) {
        let current = _report(for: owner)
        report(
            owner,
            completed: completed,
            total: total,
            fraction: current?.fraction,
            detail: current?.detail
        )
    }

    func report(_ owner: Owner, fraction: Double?) {
        let current = _report(for: owner)
        report(
            owner,
            completed: current?.completed,
            total: current?.total,
            fraction: fraction,
            detail: current?.detail
        )
    }

    func report(_ owner: Owner, detail: String?) {
        let current = _report(for: owner)
        report(
            owner,
            completed: current?.completed,
            total: current?.total,
            fraction: current?.fraction,
            detail: detail
        )
    }

    // Called before a new independent batch seeds its first snapshot. If an
    // unowned state survived an unusual early-exit path, retire it rather than
    // allowing the next task run to inherit its request/progress.
    func clearReport(_ owner: Owner) {
        var staleTask: BGContinuedProcessingTask?
        var cancelIdentifier: String?
        var removedState = false

        _lock.lock()
        if var state = _workflowStates[owner] {
            state.report = Report()
            if !state.identityClaimed && state.count == 0 {
                staleTask = state.task
                if state.requestOutstanding {
                    cancelIdentifier = state.identifier
                }
                _workflowStates.removeValue(forKey: owner)
                removedState = true
            } else {
                _workflowStates[owner] = state
            }
        }
        _lock.unlock()

        if let cancelIdentifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: cancelIdentifier)
        }
        staleTask?.setTaskCompleted(success: false)
        if removedState {
            BackgroundAudioManager.shared.releaseSystemTask(_audioKey(for: owner))
        }
    }

    // MARK: - Per-download API

    func startTask(
        for downloadId: String,
        filename: String,
        subtitle: String = "Downloading"
    ) {
        _lock.lock()
        if var state = _downloadStates[downloadId] {
            state.title = filename
            state.subtitle = subtitle

            if state.suppressed {
                // An expired/cancelled BG task cannot be reused. A deliberate
                // resume is a new continued-processing task with a fresh ID.
                state.task = nil
                state.identifier = nil
                state.handlerRegistered = false
                state.requestOutstanding = false
                state.submissionToken = nil
                state.suppressed = false
            }
            _downloadStates[downloadId] = state
        } else {
            _downloadStates[downloadId] = DownloadState(
                title: filename,
                subtitle: subtitle
            )
        }
        _lock.unlock()

        BackgroundAudioManager.shared.claimSystemTask(_audioKey(forDownload: downloadId))
        _submitDownloadIfNeeded(downloadId)
    }

    func updateProgress(for downloadId: String, progress: Double) {
        let rawValue = min(1, max(0, progress))

        // AppFileHandler reaches 100% extraction before its final move/database
        // work has completed. Reserve the system's 100% state for stopTask(), so
        // we don't surrender the continued runtime while that tail is still live.
        let percent = min(99, Int((rawValue * 100).rounded(.down)))
        let value = min(0.999_999, rawValue)
        var task: BGContinuedProcessingTask?
        var title = ""
        var subtitle = ""

        _lock.lock()
        guard var state = _downloadStates[downloadId] else {
            _lock.unlock()
            return
        }
        guard value != state.progress else {
            _lock.unlock()
            return
        }
        state.progress = value
        state.subtitle = "\(percent)%"
        task = state.task
        title = state.title
        subtitle = state.subtitle
        _downloadStates[downloadId] = state
        _lock.unlock()

        if let task {
            _applyDownloadProgress(value, title: title, subtitle: subtitle, to: task)
        }
    }

    func stopTask(for downloadId: String, success: Bool) {
        var stateToFinish: DownloadState?

        _lock.lock()
        stateToFinish = _downloadStates.removeValue(forKey: downloadId)
        _lock.unlock()

        BackgroundAudioManager.shared.releaseSystemTask(_audioKey(forDownload: downloadId))
        guard let stateToFinish else { return }

        if stateToFinish.requestOutstanding, let identifier = stateToFinish.identifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }

        if let task = stateToFinish.task {
            if success {
                _applyDownloadProgress(
                    1,
                    title: stateToFinish.title,
                    subtitle: "Completed",
                    to: task
                )
            }
            task.setTaskCompleted(success: success)
        }
    }

    // MARK: - Workflow internals

    private func _audioKey(for owner: Owner) -> String {
        "workflow:\(owner.rawValue)"
    }

    private func _audioKey(forDownload downloadId: String) -> String {
        "download:\(downloadId)"
    }

    private func _newWorkflowIdentifier(_ owner: Owner) -> String {
        "\(_baseIdentifier).workflow.\(owner.rawValue).\(UUID().uuidString)"
    }

    private func _workflowDidLaunch(
        _ owner: Owner,
        identifier: String,
        task: BGContinuedProcessingTask
    ) {
        var report = Report()
        var shouldReject = false

        _lock.lock()
        if var state = _workflowStates[owner],
           state.identifier == identifier,
           !state.suppressed {
            state.task = task
            state.requestOutstanding = false
            state.submissionToken = nil
            report = state.report
            _workflowStates[owner] = state
        } else {
            shouldReject = true
        }
        _lock.unlock()

        if shouldReject {
            task.setTaskCompleted(success: false)
            return
        }

        task.expirationHandler = { [weak self, weak task] in
            guard let self, let task else { return }
            self._workflowExpired(owner, task: task)
        }

        _apply(owner: owner, report: report, to: task)
    }

    private func _workflowExpired(_ owner: Owner, task: BGContinuedProcessingTask) {
        var ownsTask = false

        _lock.lock()
        if var state = _workflowStates[owner], state.task === task {
            state.task = nil
            state.requestOutstanding = false
            state.submissionToken = nil
            state.success = false
            state.suppressed = true
            _workflowStates[owner] = state
            ownsTask = true
        }
        _lock.unlock()

        if ownsTask {
            task.setTaskCompleted(success: false)
        }
    }

    private func _submitWorkflowIfNeeded(_ owner: Owner) {
        var request: BGContinuedProcessingTaskRequest?
        var submissionToken: UUID?
        var identifier: String?
        var mustRegister = false

        _lock.lock()
        if var state = _workflowStates[owner],
           (state.identityClaimed || state.count > 0),
           !state.suppressed,
           state.task == nil,
           !state.requestOutstanding {
            let token = UUID()
            let taskIdentifier = state.identifier ?? _newWorkflowIdentifier(owner)
            state.identifier = taskIdentifier
            state.requestOutstanding = true
            state.submissionToken = token
            mustRegister = !state.handlerRegistered
            _workflowStates[owner] = state

            let presentation = _presentation(owner: owner, report: state.report)
            let newRequest = BGContinuedProcessingTaskRequest(
                identifier: taskIdentifier,
                title: presentation.title,
                subtitle: presentation.subtitle
            )
            newRequest.strategy = .queue
            request = newRequest
            submissionToken = token
            identifier = taskIdentifier
        }
        _lock.unlock()

        guard let request, let submissionToken, let identifier else { return }

        if mustRegister {
            let registered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: identifier,
                using: nil
            ) { [weak self] task in
                guard
                    let self,
                    let continuedTask = task as? BGContinuedProcessingTask
                else { return }

                self._workflowDidLaunch(
                    owner,
                    identifier: identifier,
                    task: continuedTask
                )
            }

            guard registered else {
                _workflowRegistrationFailed(
                    owner,
                    token: submissionToken,
                    identifier: identifier
                )
                return
            }

            _lock.lock()
            if var state = _workflowStates[owner],
               state.submissionToken == submissionToken,
               state.identifier == identifier {
                state.handlerRegistered = true
                _workflowStates[owner] = state
            }
            _lock.unlock()
        }

        // The project currently builds with the iOS 26.5 SDK. That SDK exposes
        // BGContinuedProcessingTask but not iOS 27's asynchronous
        // submitTaskRequest(_:completionHandler:) API yet, so submit using the
        // supported synchronous-throwing scheduler API.
        _submissionQueue.async { [weak self] in
            guard let self,
                  self._workflowSubmissionIsCurrent(owner, token: submissionToken)
            else { return }

            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                self._workflowSubmissionCompleted(
                    owner,
                    token: submissionToken,
                    identifier: identifier,
                    error: error
                )
            }
        }
    }

    private func _workflowRegistrationFailed(
        _ owner: Owner,
        token: UUID,
        identifier: String
    ) {
        _lock.lock()
        if var state = _workflowStates[owner],
           state.submissionToken == token,
           state.identifier == identifier,
           state.task == nil {
            state.requestOutstanding = false
            state.submissionToken = nil
            _workflowStates[owner] = state
        }
        _lock.unlock()

        print("BGContinuedProcessingTask registration failed for \(identifier)")
    }

    private func _workflowSubmissionIsCurrent(_ owner: Owner, token: UUID) -> Bool {
        _lock.lock(); defer { _lock.unlock() }
        guard let state = _workflowStates[owner] else { return false }
        return state.submissionToken == token
            && state.requestOutstanding
            && state.task == nil
            && state.handlerRegistered
            && (state.identityClaimed || state.count > 0)
            && !state.suppressed
    }

    private func _workflowSubmissionCompleted(
        _ owner: Owner,
        token: UUID,
        identifier: String,
        error: Error?
    ) {
        guard let error else { return }

        var isCurrent = false
        _lock.lock()
        if var state = _workflowStates[owner],
           state.submissionToken == token,
           state.identifier == identifier,
           state.task == nil {
            state.requestOutstanding = false
            state.submissionToken = nil
            _workflowStates[owner] = state
            isCurrent = true
        }
        _lock.unlock()

        if isCurrent {
            print("Failed to submit continued processing task \(identifier): \(error)")
        }
    }

    private func _finishWorkflow(_ owner: Owner) {
        var task: BGContinuedProcessingTask?
        var identifier: String?
        var success = true
        var requestOutstanding = false
        var finalReport = Report()

        _lock.lock()
        if let state = _workflowStates.removeValue(forKey: owner) {
            task = state.task
            identifier = state.identifier
            success = state.success
            requestOutstanding = state.requestOutstanding
            finalReport = state.report
        }
        _lock.unlock()

        if requestOutstanding, let identifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }

        if let task {
            if success {
                var completedReport = finalReport
                if completedReport.fraction != nil {
                    completedReport.fraction = 1
                } else if let total = completedReport.total, total > 0 {
                    completedReport.completed = total
                }
                _apply(owner: owner, report: completedReport, to: task)
            }
            task.setTaskCompleted(success: success)
        }

        BackgroundAudioManager.shared.releaseSystemTask(_audioKey(for: owner))
    }

    private func _report(for owner: Owner) -> Report? {
        _lock.lock(); defer { _lock.unlock() }
        return _workflowStates[owner]?.report
    }

    private func _apply(
        owner: Owner,
        report: Report,
        to task: BGContinuedProcessingTask
    ) {
        let presentation = _presentation(owner: owner, report: report)
        task.updateTitle(presentation.title, subtitle: presentation.subtitle)

        if let fraction = report.fraction {
            task.progress.totalUnitCount = Self._fractionProgressUnits
            task.progress.completedUnitCount = Int64(
                (fraction * Double(Self._fractionProgressUnits)).rounded(.down)
            )
        } else if let total = report.total, total > 0, let completed = report.completed {
            task.progress.totalUnitCount = Int64(total)
            task.progress.completedUnitCount = Int64(max(0, min(completed, total)))
        } else {
            task.progress.totalUnitCount = 1
            task.progress.completedUnitCount = 0
        }
    }

    private func _presentation(
        owner: Owner,
        report: Report
    ) -> (title: String, subtitle: String) {
        var pieces: [String] = []

        if let detail = report.detail, !detail.isEmpty {
            pieces.append(detail)
        }

        if let total = report.total, total > 0, let completed = report.completed {
            pieces.append("\(max(0, min(completed, total))) of \(total)")
        } else if let fraction = report.fraction {
            pieces.append("\(Int((fraction * 100).rounded()))%")
        }

        if pieces.isEmpty {
            pieces.append("Working")
        }

        return (owner.title, pieces.joined(separator: " · "))
    }

    // MARK: - Download internals

    private func _newDownloadIdentifier() -> String {
        "\(_baseIdentifier).download.\(UUID().uuidString)"
    }

    private func _downloadDidLaunch(
        _ downloadId: String,
        identifier: String,
        task: BGContinuedProcessingTask
    ) {
        var stateToApply: DownloadState?

        _lock.lock()
        if var state = _downloadStates[downloadId],
           state.identifier == identifier,
           !state.suppressed {
            state.task = task
            state.requestOutstanding = false
            state.submissionToken = nil
            _downloadStates[downloadId] = state
            stateToApply = state
        }
        _lock.unlock()

        guard let stateToApply else {
            task.setTaskCompleted(success: false)
            return
        }

        task.expirationHandler = { [weak self, weak task] in
            guard let self, let task else { return }
            self._downloadExpired(downloadId, task: task)
        }

        _applyDownloadProgress(
            stateToApply.progress,
            title: stateToApply.title,
            subtitle: stateToApply.subtitle,
            to: task
        )
    }

    private func _downloadExpired(_ downloadId: String, task: BGContinuedProcessingTask) {
        var ownsTask = false

        _lock.lock()
        if var state = _downloadStates[downloadId], state.task === task {
            state.task = nil
            state.requestOutstanding = false
            state.submissionToken = nil
            state.suppressed = true
            _downloadStates[downloadId] = state
            ownsTask = true
        }
        _lock.unlock()

        guard ownsTask else { return }

        DispatchQueue.main.async {
            if let download = DownloadManager.shared.getDownload(by: downloadId) {
                DownloadManager.shared.cancelDownload(download)
            }
        }
        task.setTaskCompleted(success: false)
    }

    private func _submitDownloadIfNeeded(_ downloadId: String) {
        var request: BGContinuedProcessingTaskRequest?
        var submissionToken: UUID?
        var identifier: String?
        var mustRegister = false

        _lock.lock()
        if var state = _downloadStates[downloadId],
           !state.suppressed,
           state.task == nil,
           !state.requestOutstanding {
            let token = UUID()
            let taskIdentifier = state.identifier ?? _newDownloadIdentifier()
            state.identifier = taskIdentifier
            state.requestOutstanding = true
            state.submissionToken = token
            mustRegister = !state.handlerRegistered
            _downloadStates[downloadId] = state

            let newRequest = BGContinuedProcessingTaskRequest(
                identifier: taskIdentifier,
                title: state.title,
                subtitle: state.subtitle
            )
            newRequest.strategy = .queue
            request = newRequest
            submissionToken = token
            identifier = taskIdentifier
        }
        _lock.unlock()

        guard let request, let submissionToken, let identifier else { return }

        if mustRegister {
            let registered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: identifier,
                using: nil
            ) { [weak self] task in
                guard
                    let self,
                    let continuedTask = task as? BGContinuedProcessingTask
                else { return }

                self._downloadDidLaunch(
                    downloadId,
                    identifier: identifier,
                    task: continuedTask
                )
            }

            guard registered else {
                _downloadRegistrationFailed(
                    downloadId,
                    token: submissionToken,
                    identifier: identifier
                )
                return
            }

            _lock.lock()
            if var state = _downloadStates[downloadId],
               state.submissionToken == submissionToken,
               state.identifier == identifier {
                state.handlerRegistered = true
                _downloadStates[downloadId] = state
            }
            _lock.unlock()
        }

        _submissionQueue.async { [weak self] in
            guard let self,
                  self._downloadSubmissionIsCurrent(downloadId, token: submissionToken)
            else { return }

            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                self._downloadSubmissionCompleted(
                    downloadId,
                    token: submissionToken,
                    identifier: identifier,
                    error: error
                )
            }
        }
    }

    private func _downloadRegistrationFailed(
        _ downloadId: String,
        token: UUID,
        identifier: String
    ) {
        _lock.lock()
        if var state = _downloadStates[downloadId],
           state.submissionToken == token,
           state.identifier == identifier,
           state.task == nil {
            state.requestOutstanding = false
            state.submissionToken = nil
            _downloadStates[downloadId] = state
        }
        _lock.unlock()

        print("BGContinuedProcessingTask registration failed for \(identifier)")
    }

    private func _downloadSubmissionIsCurrent(_ downloadId: String, token: UUID) -> Bool {
        _lock.lock(); defer { _lock.unlock() }
        guard let state = _downloadStates[downloadId] else { return false }
        return state.submissionToken == token
            && state.requestOutstanding
            && state.task == nil
            && state.handlerRegistered
            && !state.suppressed
    }

    private func _downloadSubmissionCompleted(
        _ downloadId: String,
        token: UUID,
        identifier: String,
        error: Error?
    ) {
        guard let error else { return }

        var isCurrent = false
        _lock.lock()
        if var state = _downloadStates[downloadId],
           state.submissionToken == token,
           state.identifier == identifier,
           state.task == nil {
            state.requestOutstanding = false
            state.submissionToken = nil
            _downloadStates[downloadId] = state
            isCurrent = true
        }
        _lock.unlock()

        if isCurrent {
            print("Failed to submit download continued processing task \(identifier): \(error)")
        }
    }

    private func _applyDownloadProgress(
        _ progress: Double,
        title: String,
        subtitle: String,
        to task: BGContinuedProcessingTask
    ) {
        task.progress.totalUnitCount = Self._fractionProgressUnits
        task.progress.completedUnitCount = Int64(
            (min(1, max(0, progress)) * Double(Self._fractionProgressUnits)).rounded(.down)
        )
        task.updateTitle(title, subtitle: subtitle)
    }
}

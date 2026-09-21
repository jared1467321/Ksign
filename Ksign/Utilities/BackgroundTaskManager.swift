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

        func title(total: Int?) -> String {
            let count = total.flatMap { $0 > 0 ? $0 : nil }
            switch self {
            case .bulkInstalls:
                return count.map { "Installing \($0) \($0 == 1 ? "App" : "Apps")" } ?? "Installing Apps"
            case .singleInstall:
                return "Installing App"
            case .bulkExport:
                return count.map { "Exporting \($0) \($0 == 1 ? "App" : "Apps")" } ?? "Exporting Apps"
            case .importing:
                return count.map { "Importing \($0) \($0 == 1 ? "IPA" : "IPAs")" } ?? "Importing IPAs"
            case .signing:
                return count.map { "Signing \($0) \($0 == 1 ? "App" : "Apps")" } ?? "Signing Apps"
            case .extracting:
                return count.map { "Extracting \($0) \($0 == 1 ? "IPA" : "IPAs")" } ?? "Extracting IPAs"
            case .ipaVaultDownloads:
                return count.map { "Downloading \($0) \($0 == 1 ? "IPA" : "IPAs")" } ?? "IPA Vault Downloads"
            }
        }
    }

    private struct Report: Equatable {
        var completed: Int?
        var total: Int?
        var fraction: Double?
        var detail: String?
        var currentItem: String?
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

    private struct DownloadItemState {
        var filename: String
        var progress: Double = 0
        var terminal = false
        var success = true
        var sequence = 0
    }

    private struct DownloadBatchState {
        var task: BGContinuedProcessingTask?
        var identifier: String?
        var handlerRegistered = false
        var requestOutstanding = false
        var submissionToken: UUID?
        var items: [String: DownloadItemState] = [:]
        var sequence = 0
        var currentDownloadId: String?
        var success = true
        var suppressed = false
    }

    private let _lock = NSLock()
    private let _submissionQueue = DispatchQueue(
        label: "AppAssassin.signer.ipa.background-task-submission",
        qos: .userInitiated
    )
    private var _workflowStates: [Owner: WorkflowState] = [:]
    private var _downloadBatchState: DownloadBatchState?

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
        detail: String?,
        currentItem: String? = nil
    ) {
        let normalizedDetail: String? = {
            let value = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }()
        let normalizedCurrentItem: String? = {
            let value = currentItem?.trimmingCharacters(in: .whitespacesAndNewlines)
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
            detail: normalizedDetail,
            currentItem: normalizedCurrentItem
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
            detail: current?.detail,
            currentItem: current?.currentItem
        )
    }

    func report(_ owner: Owner, fraction: Double?) {
        let current = _report(for: owner)
        report(
            owner,
            completed: current?.completed,
            total: current?.total,
            fraction: fraction,
            detail: current?.detail,
            currentItem: current?.currentItem
        )
    }

    func report(_ owner: Owner, detail: String?) {
        let current = _report(for: owner)
        report(
            owner,
            completed: current?.completed,
            total: current?.total,
            fraction: current?.fraction,
            detail: detail,
            currentItem: current?.currentItem
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

    // MARK: - Aggregate download API

    // All regular network downloads share one continued-processing task. The
    // system Live Activity therefore shows one aggregate percentage for the
    // whole active batch and the file that most recently made progress.
    func startTask(
        for downloadId: String,
        filename: String,
        subtitle: String = "Downloading"
    ) {
        var task: BGContinuedProcessingTask?
        var snapshot: (progress: Double, title: String, subtitle: String)?
        var shouldClaimAudio = false

        _lock.lock()
        if _downloadBatchState == nil || (_downloadBatchState?.suppressed == true && _downloadBatchState?.items.values.allSatisfy(\.terminal) == true) {
            _downloadBatchState = DownloadBatchState()
            shouldClaimAudio = true
        }

        guard var state = _downloadBatchState, !state.suppressed else {
            _lock.unlock()
            return
        }

        state.sequence += 1
        var item = state.items[downloadId] ?? DownloadItemState(filename: filename)
        item.filename = filename
        item.terminal = false
        item.success = true
        item.sequence = state.sequence
        state.items[downloadId] = item
        state.currentDownloadId = downloadId
        state.success = state.items.values.allSatisfy { !$0.terminal || $0.success }
        task = state.task
        snapshot = _downloadPresentation(state)
        _downloadBatchState = state
        _lock.unlock()

        if shouldClaimAudio {
            BackgroundAudioManager.shared.claimSystemTask(_downloadAudioKey)
        }
        if let task, let snapshot {
            _applyDownloadProgress(snapshot.progress, title: snapshot.title, subtitle: snapshot.subtitle, to: task)
        }
        _submitDownloadIfNeeded()
    }

    func updateProgress(for downloadId: String, progress: Double) {
        let rawValue = min(1, max(0, progress))

        // AppFileHandler reaches 100% extraction before its final move/database
        // work has completed. Reserve the system's 100% state for stopTask(), so
        // we don't surrender the continued runtime while that tail is still live.
        let value = min(0.999_999, rawValue)
        var task: BGContinuedProcessingTask?
        var snapshot: (progress: Double, title: String, subtitle: String)?

        _lock.lock()
        guard var state = _downloadBatchState,
              !state.suppressed,
              var item = state.items[downloadId],
              !item.terminal else {
            _lock.unlock()
            return
        }
        guard value != item.progress else {
            _lock.unlock()
            return
        }

        state.sequence += 1
        item.progress = value
        item.sequence = state.sequence
        state.items[downloadId] = item
        state.currentDownloadId = downloadId
        task = state.task
        snapshot = _downloadPresentation(state)
        _downloadBatchState = state
        _lock.unlock()

        if let task, let snapshot {
            _applyDownloadProgress(snapshot.progress, title: snapshot.title, subtitle: snapshot.subtitle, to: task)
        }
    }

    func stopTask(for downloadId: String, success: Bool) {
        var task: BGContinuedProcessingTask?
        var cancelIdentifier: String?
        var snapshot: (progress: Double, title: String, subtitle: String)?
        var shouldFinish = false
        var batchSucceeded = true

        _lock.lock()
        guard var state = _downloadBatchState,
              var item = state.items[downloadId],
              !item.terminal else {
            _lock.unlock()
            return
        }

        state.sequence += 1
        item.progress = 1
        item.terminal = true
        item.success = success
        item.sequence = state.sequence
        state.items[downloadId] = item
        state.success = state.success && success

        let activeItems = state.items.filter { !$0.value.terminal }
        if let current = activeItems.max(by: { $0.value.sequence < $1.value.sequence }) {
            state.currentDownloadId = current.key
        } else {
            state.currentDownloadId = downloadId
        }

        task = state.task
        snapshot = _downloadPresentation(state)
        shouldFinish = activeItems.isEmpty
        batchSucceeded = state.success

        if shouldFinish {
            if state.requestOutstanding {
                cancelIdentifier = state.identifier
            }
            _downloadBatchState = nil
        } else {
            _downloadBatchState = state
        }
        _lock.unlock()

        if let task, let snapshot {
            _applyDownloadProgress(snapshot.progress, title: snapshot.title, subtitle: snapshot.subtitle, to: task)
        }

        if shouldFinish {
            if let cancelIdentifier {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: cancelIdentifier)
            }
            task?.setTaskCompleted(success: batchSucceeded)
            BackgroundAudioManager.shared.releaseSystemTask(_downloadAudioKey)
        }
    }

    // MARK: - Workflow internals

    private func _audioKey(for owner: Owner) -> String {
        "workflow:\(owner.rawValue)"
    }

    private var _downloadAudioKey: String { "download-batch" }

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

        let displayFraction: Double? = {
            if let fraction = report.fraction {
                return min(1, max(0, fraction))
            }
            guard let total = report.total, total > 0, let completed = report.completed else {
                return nil
            }
            return min(1, max(0, Double(completed) / Double(total)))
        }()

        if let displayFraction {
            pieces.append("\(Int((displayFraction * 100).rounded()))%")
        }

        if let currentItem = report.currentItem, !currentItem.isEmpty {
            pieces.append(currentItem)
        }

        // The owner title already communicates the active phase. Keep ordinary
        // subtitles compact ("67% · Apollo.ipa"), but preserve terminal/error
        // state when it adds information the percentage cannot.
        if report.detail == "Error" || report.detail == "Cancelled" || report.detail == "Paused" {
            pieces.append(report.detail!)
        } else if pieces.isEmpty, let detail = report.detail, !detail.isEmpty {
            pieces.append(detail)
        }

        if pieces.isEmpty {
            pieces.append("Working")
        }

        return (owner.title(total: report.total), pieces.joined(separator: " · "))
    }

    // MARK: - Download internals

    private func _newDownloadIdentifier() -> String {
        "\(_baseIdentifier).download.\(UUID().uuidString)"
    }

    private func _downloadPresentation(
        _ state: DownloadBatchState
    ) -> (progress: Double, title: String, subtitle: String) {
        let total = state.items.count
        let progress: Double
        if total > 0 {
            progress = min(
                1,
                max(0, state.items.values.reduce(0.0) { $0 + $1.progress } / Double(total))
            )
        } else {
            progress = 0
        }

        let currentID: String? = {
            if let id = state.currentDownloadId,
               let item = state.items[id],
               !item.terminal {
                return id
            }
            return state.items
                .filter { !$0.value.terminal }
                .max(by: { $0.value.sequence < $1.value.sequence })?.key
                ?? state.currentDownloadId
        }()
        let filename = currentID.flatMap { state.items[$0]?.filename }
        let percent = Int((progress * 100).rounded())
        let title = total == 1 ? "Downloading IPA" : "Downloading \(total) IPAs"
        let subtitle: String
        if let filename, !filename.isEmpty {
            subtitle = "\(percent)% · \(filename)"
        } else {
            subtitle = "\(percent)%"
        }
        return (progress, title, subtitle)
    }

    private func _downloadDidLaunch(
        identifier: String,
        task: BGContinuedProcessingTask
    ) {
        var snapshot: (progress: Double, title: String, subtitle: String)?

        _lock.lock()
        if var state = _downloadBatchState,
           state.identifier == identifier,
           !state.suppressed {
            state.task = task
            state.requestOutstanding = false
            state.submissionToken = nil
            snapshot = _downloadPresentation(state)
            _downloadBatchState = state
        }
        _lock.unlock()

        guard let snapshot else {
            task.setTaskCompleted(success: false)
            return
        }

        task.expirationHandler = { [weak self, weak task] in
            guard let self, let task else { return }
            self._downloadExpired(task: task)
        }

        _applyDownloadProgress(
            snapshot.progress,
            title: snapshot.title,
            subtitle: snapshot.subtitle,
            to: task
        )
    }

    private func _downloadExpired(task: BGContinuedProcessingTask) {
        var downloadIDs: [String] = []
        var ownsTask = false
        var releaseAudioImmediately = false

        _lock.lock()
        if var state = _downloadBatchState, state.task === task {
            state.task = nil
            state.requestOutstanding = false
            state.submissionToken = nil
            state.success = false
            state.suppressed = true
            downloadIDs = state.items.compactMap { $0.value.terminal ? nil : $0.key }
            releaseAudioImmediately = downloadIDs.isEmpty
            if releaseAudioImmediately {
                _downloadBatchState = nil
            } else {
                _downloadBatchState = state
            }
            ownsTask = true
        }
        _lock.unlock()

        guard ownsTask else { return }

        task.setTaskCompleted(success: false)
        if releaseAudioImmediately {
            BackgroundAudioManager.shared.releaseSystemTask(_downloadAudioKey)
            return
        }

        DispatchQueue.main.async {
            for downloadID in downloadIDs {
                if let download = DownloadManager.shared.getDownload(by: downloadID) {
                    DownloadManager.shared.cancelDownload(download)
                }
            }
        }
    }

    private func _submitDownloadIfNeeded() {
        var request: BGContinuedProcessingTaskRequest?
        var submissionToken: UUID?
        var identifier: String?
        var mustRegister = false

        _lock.lock()
        if var state = _downloadBatchState,
           !state.suppressed,
           !state.items.isEmpty,
           state.task == nil,
           !state.requestOutstanding {
            let token = UUID()
            let taskIdentifier = state.identifier ?? _newDownloadIdentifier()
            state.identifier = taskIdentifier
            state.requestOutstanding = true
            state.submissionToken = token
            mustRegister = !state.handlerRegistered
            let snapshot = _downloadPresentation(state)
            _downloadBatchState = state

            let newRequest = BGContinuedProcessingTaskRequest(
                identifier: taskIdentifier,
                title: snapshot.title,
                subtitle: snapshot.subtitle
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
                    identifier: identifier,
                    task: continuedTask
                )
            }

            guard registered else {
                _downloadRegistrationFailed(token: submissionToken, identifier: identifier)
                return
            }

            _lock.lock()
            if var state = _downloadBatchState,
               state.submissionToken == submissionToken,
               state.identifier == identifier {
                state.handlerRegistered = true
                _downloadBatchState = state
            }
            _lock.unlock()
        }

        _submissionQueue.async { [weak self] in
            guard let self,
                  self._downloadSubmissionIsCurrent(token: submissionToken)
            else { return }

            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                self._downloadSubmissionCompleted(
                    token: submissionToken,
                    identifier: identifier,
                    error: error
                )
            }
        }
    }

    private func _downloadRegistrationFailed(
        token: UUID,
        identifier: String
    ) {
        _lock.lock()
        if var state = _downloadBatchState,
           state.submissionToken == token,
           state.identifier == identifier,
           state.task == nil {
            state.requestOutstanding = false
            state.submissionToken = nil
            _downloadBatchState = state
        }
        _lock.unlock()

        print("BGContinuedProcessingTask registration failed for \(identifier)")
    }

    private func _downloadSubmissionIsCurrent(token: UUID) -> Bool {
        _lock.lock(); defer { _lock.unlock() }
        guard let state = _downloadBatchState else { return false }
        return state.submissionToken == token
            && state.requestOutstanding
            && state.task == nil
            && state.handlerRegistered
            && !state.suppressed
            && !state.items.isEmpty
    }

    private func _downloadSubmissionCompleted(
        token: UUID,
        identifier: String,
        error: Error?
    ) {
        guard let error else { return }

        var isCurrent = false
        _lock.lock()
        if var state = _downloadBatchState,
           state.submissionToken == token,
           state.identifier == identifier,
           state.task == nil {
            state.requestOutstanding = false
            state.submissionToken = nil
            _downloadBatchState = state
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

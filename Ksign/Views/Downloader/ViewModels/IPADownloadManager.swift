//
//  IPADownloadManager.swift
//  Ksign
//
//  Created by Nagata Asami on 5/24/25.
//

import SwiftUI
import WebKit
import Darwin

class IPADownloadManager: NSObject, ObservableObject {
    @Published var downloadItems: [DownloadItem] = []
    
    var activeItems: [DownloadItem] {
        downloadItems.filter { !$0.isFinished }
    }
    
    var finishedItems: [DownloadItem] {
        downloadItems.filter { $0.isFinished }
    }

    private struct PendingIPAVaultDownload {
        let itemID: String
        let url: URL
        let totalBytes: Int64
    }

    private struct IPAVaultRange {
        var start: Int64
        var end: Int64 // exclusive
        var attempt: Int

        var length: Int64 {
            max(0, end - start)
        }
    }

    private struct IPAVaultWorkerRateSample {
        let time: TimeInterval
        let bytes: Int64
    }

    private struct IPAVaultAggregateSample {
        let time: TimeInterval
        let bytes: Int64
    }

    private enum IPAVaultBatchProbeDimension: Equatable {
        case concurrency
        case streams
    }

    private enum IPAVaultBatchTuningPhase {
        case concurrency
        case streams
        case steady
    }

    private final class IPAVaultBatchAdaptiveProbe {
        let dimension: IPAVaultBatchProbeDimension
        let previousValue: Int
        let targetValue: Int
        let baselineBPS: Double
        let noiseFraction: Double
        let requestedAt: TimeInterval
        let isSteadyProbe: Bool
        var measurementStartedAt: TimeInterval?
        var samples: [Double] = []

        init(
            dimension: IPAVaultBatchProbeDimension,
            previousValue: Int,
            targetValue: Int,
            baselineBPS: Double,
            noiseFraction: Double,
            requestedAt: TimeInterval,
            isSteadyProbe: Bool
        ) {
            self.dimension = dimension
            self.previousValue = previousValue
            self.targetValue = targetValue
            self.baselineBPS = baselineBPS
            self.noiseFraction = noiseFraction
            self.requestedAt = requestedAt
            self.isSteadyProbe = isSteadyProbe
        }
    }

    private final class IPAVaultTaskMetadata {
        let itemID: String
        let leaseStart: Int64
        let requestEnd: Int64
        let attempt: Int
        let startedAt: TimeInterval
        var effectiveEnd: Int64
        var currentPosition: Int64
        var committedEnd: Int64
        var lastProgressAt: TimeInterval
        var responseValidated = false
        var terminalError: Error?
        var preempted = false
        var suppressCompletion = false
        var rateSamples: [IPAVaultWorkerRateSample]

        init(
            itemID: String,
            leaseStart: Int64,
            requestEnd: Int64,
            attempt: Int,
            startedAt: TimeInterval
        ) {
            self.itemID = itemID
            self.leaseStart = leaseStart
            self.requestEnd = requestEnd
            self.attempt = attempt
            self.startedAt = startedAt
            self.effectiveEnd = requestEnd
            self.currentPosition = leaseStart
            self.committedEnd = leaseStart
            self.lastProgressAt = startedAt
            self.rateSamples = [IPAVaultWorkerRateSample(time: startedAt, bytes: 0)]
        }
    }

    private final class IPAVaultJob {
        let itemID: String
        let url: URL
        let totalBytes: Int64
        let directory: URL
        let partialURL: URL
        var fileDescriptor: Int32
        var freeRanges: [IPAVaultRange]
        var tasks: [Int: URLSessionDataTask] = [:]
        var committedBytes: Int64 = 0
        var assembling = false
        var recentCompletedRates: [Double] = []

        // The batch controller owns the target. Keeping it on each job lets stream
        // reductions drain already-issued leases without cancelling useful bytes.
        var desiredStreams: Int

        init(
            itemID: String,
            url: URL,
            totalBytes: Int64,
            directory: URL,
            partialURL: URL,
            fileDescriptor: Int32,
            startingStreams: Int
        ) {
            self.itemID = itemID
            self.url = url
            self.totalBytes = totalBytes
            self.directory = directory
            self.partialURL = partialURL
            self.fileDescriptor = fileDescriptor
            self.desiredStreams = min(10, max(1, startingStreams))
            self.freeRanges = [IPAVaultRange(start: 0, end: totalBytes, attempt: 0)]
        }
    }

    private var urlSession: URLSession!
    private var activeDownloads: [Int: String] = [:] // taskIdentifier -> downloadItem.id

    // IPA Vault owns its own ranged transport. Every new batch starts conservatively
    // at one IPA with two streams, then tunes both dimensions from real download
    // traffic. No learned transport state survives the batch.
    private var pendingIPAVaultDownloads: [PendingIPAVaultDownload] = []
    private var activeIPAVaultDownloadIDs: Set<String> = []
    private var ipavaultJobs: [String: IPAVaultJob] = [:]
    private var ipavaultTaskMetadata: [Int: IPAVaultTaskMetadata] = [:]
    private var pausedIPAVaultDownloadIDs: Set<String> = []
    private var resumeRequestedIPAVaultDownloadIDs: Set<String> = []
    private var tunerSuspendedIPAVaultDownloadIDs: Set<String> = []

    private let ipavaultHardMaxConcurrentDownloads = 8
    private let ipavaultHardMaxStreamsPerFile = 10
    private let ipavaultBatchInitialStreamsPerFile = 2
    private var maxConcurrentIPAVaultDownloads = 1

    private var ipavaultBatchIsActive = false
    private var ipavaultBatchTargetConcurrency = 1
    private var ipavaultBatchTargetStreams = 2
    private var ipavaultBatchTuningPhase: IPAVaultBatchTuningPhase = .concurrency
    private var ipavaultBatchProbe: IPAVaultBatchAdaptiveProbe?
    private var ipavaultBatchControllerThroughputSamples: [(time: TimeInterval, bps: Double)] = []
    private var ipavaultBatchConcurrencyUpperBound: Int?
    private var ipavaultBatchStreamsUpperBound: Int?
    private var ipavaultBatchLastDecisionAt: TimeInterval = 0
    private var ipavaultBatchLastStableBPS: Double = 0
    private var ipavaultBatchNextSteadyProbeAt: TimeInterval = 0
    private var ipavaultBatchSteadyProbeStep = 0

    @Published private(set) var ipavaultAdaptiveConcurrentCount = 0
    @Published private(set) var ipavaultAdaptiveStreamsPerFile = 2
    @Published private(set) var ipavaultAdaptiveStatus = "Idle"
    @Published private(set) var ipavaultAdaptiveStreamCount = 0
    @Published private(set) var ipavaultAdaptiveSpeedBPS: Double = 0

    private let ipavaultBlockSize: Int64 = 256 * 1024
    private let ipavaultMinimumLeaseBytes: Int64 = 2 * 1024 * 1024
    private let ipavaultDefaultLeaseBytes: Int64 = 8 * 1024 * 1024
    private let ipavaultMaximumLeaseBytes: Int64 = 64 * 1024 * 1024
    private let ipavaultLeaseTargetSeconds: Double = 2.0
    private let ipavaultTailMinimumBytes: Int64 = 512 * 1024
    private let ipavaultTailMinimumSavingsSeconds: Double = 0.75
    private let ipavaultSpeedWindowSeconds: Double = 1.00
    private let ipavaultControllerTickSeconds: Double = 0.50
    private let ipavaultProbeSettleSeconds: Double = 0.75
    private let ipavaultProbeMeasureSeconds: Double = 1.25
    private let ipavaultSteadyRetuneSeconds: Double = 15.0
    private let ipavaultWorkerStallSeconds: Double = 3.0
    private let ipavaultStallDetectionFloorSeconds: Double = 4.0
    private let ipavaultMaximumRangeRetries = 5

    private var ipavaultAdaptiveTimer: Timer?
    private var ipavaultTotalUsefulBytes: Int64 = 0
    private var ipavaultAggregateRateSamples: [IPAVaultAggregateSample] = []

    // System background-task progress accounting is intentionally separate from the queue.
    private struct IPAVaultBackgroundTaskSnapshot: Equatable {
        let completed: Int
        let total: Int
        let fraction: Double
        let detail: String
        let currentItem: String?
    }

    private var ipavaultActivityItemIDs: Set<String> = []
    private var completedIPAVaultActivityItemIDs: Set<String> = []
    private var ipavaultCurrentActivityItemID: String?
    private var ipavaultBackgroundTaskSnapshot: IPAVaultBackgroundTaskSnapshot?

    private var ipavaultTransfersRootURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KsignIPAVault", isDirectory: true)
            .appendingPathComponent("transfers", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private lazy var ipavaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 80
        return URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
    }()

    override init() {
        super.init()
        setupURLSession()
        _ = ipavaultSession
        loadDownloadedIPAs()
    }
    
    private func setupURLSession() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300 // 5 minutes
        config.waitsForConnectivity = true
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func isIPAFile(_ url: URL) -> Bool {
        return url.pathExtension.lowercased() == "ipa"
    }

    func loadDownloadedIPAs() {
        let fileManager = FileManager.default
        let downloadDirectory = URL.documentsDirectory.appendingPathComponent("Downloads")
        
        let activeDownloads = downloadItems.filter { !$0.isFinished }
        // Build one snapshot and keep existing local row identities. Publishing
        // an empty list followed by one append per IPA churns every row when a
        // download finishes (including when the active section disappears).
        let existingDownloads = downloadItems.filter { $0.isFinished }
        var refreshedItems = activeDownloads
        
        do {
            try fileManager.createDirectoryIfNeeded(at: downloadDirectory)
            let fileURLs = try fileManager.contentsOfDirectory(at: downloadDirectory, includingPropertiesForKeys: [.fileSizeKey], options: [])
            
            for fileURL in fileURLs {
                if isIPAFile(fileURL) {
                    if activeDownloads.contains(where: { $0.localPath == fileURL }) {
                        continue
                    }
                    
                    let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                    let fileSize = attributes[.size] as? Int64 ?? 0

                    if var existing = existingDownloads.first(where: { $0.localPath == fileURL }) {
                        existing.url = fileURL
                        existing.totalBytes = fileSize
                        existing.bytesDownloaded = fileSize
                        refreshedItems.append(existing)
                        continue
                    }
                    
                    let item = DownloadItem(
                        title: fileURL.lastPathComponent,
                        url: fileURL,
                        localPath: fileURL,
                        isFinished: true,
                        progress: 1.0,
                        totalBytes: fileSize,
                        bytesDownloaded: fileSize
                    )
                    refreshedItems.append(item)
                }
            }
            downloadItems = refreshedItems
        } catch {
            print("Failed to load downloaded IPAs: \(error)")
        }
    }
    
    // Ordinary Ksign downloads intentionally keep their original single-task behavior.
    func startDownload(url: URL, filename: String) {
        let fileManager = FileManager.default
        let downloadDirectory = URL.documentsDirectory.appendingPathComponent("Downloads")
        try? fileManager.createDirectoryIfNeeded(at: downloadDirectory)
        
        let destinationURL = downloadDirectory.appendingPathComponent(filename)
        let item = DownloadItem(
            title: filename,
            url: url,
            localPath: destinationURL,
            isFinished: false,
            progress: 0,
            totalBytes: 0,
            bytesDownloaded: 0
        )
        
        DispatchQueue.main.async {
            self.downloadItems.insert(item, at: 0)
        }
        
        let task = urlSession.downloadTask(with: url)
        activeDownloads[task.taskIdentifier] = item.id.uuidString
        task.resume()
    }

    /// Queues IPA Vault server -> Downloads transfers. Each batch self-tunes from
    /// one IPA at two streams, using aggregate useful throughput as the objective.
    func enqueueIPAVaultDownloads(_ files: [(url: URL, filename: String, size: Int64)]) {
        let work = {
            let fileManager = FileManager.default
            let downloadDirectory = URL.documentsDirectory.appendingPathComponent("Downloads")
            try? fileManager.createDirectoryIfNeeded(at: downloadDirectory)

            for file in files where file.size > 0 {
                let item = DownloadItem(
                    title: file.filename,
                    url: file.url,
                    localPath: downloadDirectory.appendingPathComponent(file.filename),
                    isFinished: false,
                    progress: 0,
                    totalBytes: file.size,
                    bytesDownloaded: 0,
                    isIPAVaultDownload: true
                )
                self.downloadItems.insert(item, at: 0)
                self.pendingIPAVaultDownloads.append(
                    PendingIPAVaultDownload(
                        itemID: item.id.uuidString,
                        url: file.url,
                        totalBytes: file.size
                    )
                )
                self.ipavaultActivityItemIDs.insert(item.id.uuidString)
            }

            self.updateIPAVaultBackgroundTaskState()
            self.pumpIPAVaultDownloadQueue()
            self.startIPAVaultAdaptiveControllerIfNeeded()
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // IPA Vault uses foreground ranged requests, so claim one continued-processing
    // task for the entire queue, including the tiny final fsync/move phase.
    private func updateIPAVaultBackgroundTaskState() {
        dispatchPrecondition(condition: .onQueue(.main))

        let hasWork = !pendingIPAVaultDownloads.isEmpty || !activeIPAVaultDownloadIDs.isEmpty

        if hasWork {
            if !ipavaultBatchIsActive {
                beginIPAVaultBatch()
            }

            publishIPAVaultBackgroundTaskState()
            BackgroundTaskManager.shared.claim(.ipaVaultDownloads)
        } else {
            // Publish the terminal snapshot before completing the system task.
            publishIPAVaultBackgroundTaskState()
            let total = ipavaultActivityItemIDs.count
            let completed = completedIPAVaultActivityItemIDs
                .intersection(ipavaultActivityItemIDs)
                .count
            BackgroundTaskManager.shared.release(
                .ipaVaultDownloads,
                success: total == 0 || completed >= total
            )

            ipavaultActivityItemIDs.removeAll()
            completedIPAVaultActivityItemIDs.removeAll()
            ipavaultCurrentActivityItemID = nil
            ipavaultBackgroundTaskSnapshot = nil
            stopIPAVaultAdaptiveController()
            endIPAVaultBatch()
        }
    }

    /// Keeps the Live Activity filename stable while IPA Vault downloads run concurrently.
    /// The selected item remains pinned until it reaches a terminal state, then advances to
    /// the oldest remaining item from the original queue order.
    private func stickyIPAVaultActivityItemID() -> String? {
        if let current = ipavaultCurrentActivityItemID,
           ipavaultActivityItemIDs.contains(current),
           !completedIPAVaultActivityItemIDs.contains(current) {
            return current
        }

        let next = downloadItems.reversed().first { item in
            let itemID = item.id.uuidString
            return ipavaultActivityItemIDs.contains(itemID) &&
                !completedIPAVaultActivityItemIDs.contains(itemID)
        }?.id.uuidString

        ipavaultCurrentActivityItemID = next
        return next
    }

    private func publishIPAVaultBackgroundTaskState() {
        dispatchPrecondition(condition: .onQueue(.main))
        let total = ipavaultActivityItemIDs.count
        guard total > 0 else { return }

        let completed = completedIPAVaultActivityItemIDs
            .intersection(ipavaultActivityItemIDs)
            .count

        let isFinishing = !activeIPAVaultDownloadIDs.isEmpty &&
            activeIPAVaultDownloadIDs.allSatisfy { ipavaultJobs[$0]?.assembling == true }
        let detail: String
        if completed >= total {
            detail = "Completed"
        } else if isFinishing {
            detail = "Finishing IPA Vault downloads"
        } else {
            detail = "Downloading from IPA Vault"
        }
        let progressByID = Dictionary(
            uniqueKeysWithValues: downloadItems.map { ($0.id.uuidString, min(1, max(0, $0.progress))) }
        )
        let aggregateFraction = min(
            1,
            max(
                0,
                ipavaultActivityItemIDs.reduce(0.0) { partial, itemID in
                    if completedIPAVaultActivityItemIDs.contains(itemID) {
                        return partial + 1
                    }
                    return partial + (progressByID[itemID] ?? 0)
                } / Double(total)
            )
        )

        // IPA Vault can receive many data callbacks per second. Reporting every tiny
        // fraction change to BGContinuedProcessingTask needlessly floods the system
        // Live Activity path. Keep system progress at whole-percent granularity, and
        // reserve 100% for the real terminal snapshot so completion is never shown early.
        let reportedPercent = completed >= total
            ? 100
            : min(99, Int((aggregateFraction * 100).rounded(.down)))
        let reportedFraction = Double(reportedPercent) / 100

        let currentItemID = stickyIPAVaultActivityItemID()
        let currentItem = currentItemID.flatMap { itemID in
            downloadItems.first(where: { $0.id.uuidString == itemID })?.title
        }

        let snapshot = IPAVaultBackgroundTaskSnapshot(
            completed: completed,
            total: total,
            fraction: reportedFraction,
            detail: detail,
            currentItem: currentItem
        )
        guard snapshot != ipavaultBackgroundTaskSnapshot else { return }
        ipavaultBackgroundTaskSnapshot = snapshot

        BackgroundTaskManager.shared.report(
            .ipaVaultDownloads,
            completed: completed,
            total: total,
            fraction: reportedFraction,
            detail: detail,
            currentItem: currentItem
        )
    }

    func pauseIPAVaultDownload(_ item: DownloadItem) {
        let work = {
            let itemID = item.id.uuidString
            guard item.isIPAVaultDownload, !item.isFinished else { return }
            guard !self.pausedIPAVaultDownloadIDs.contains(itemID) else { return }
            guard self.ipavaultJobs[itemID] != nil || self.pendingIPAVaultDownloads.contains(where: { $0.itemID == itemID }) else { return }

            if let job = self.ipavaultJobs[itemID], job.assembling {
                return
            }

            self.resumeRequestedIPAVaultDownloadIDs.remove(itemID)
            self.pausedIPAVaultDownloadIDs.insert(itemID)

            if let job = self.ipavaultJobs[itemID] {
                self.cancelIPAVaultStreams(job, requeueUnfinished: true)
                self.tunerSuspendedIPAVaultDownloadIDs.remove(itemID)
                job.desiredStreams = self.ipavaultBatchTargetStreams
            }
            self.setIPAVaultPausedState(itemID: itemID, isPaused: true)
            self.pumpIPAVaultDownloadQueue()
            self.rebalanceIPAVaultStreams()
            self.updateIPAVaultBackgroundTaskState()
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    func resumeIPAVaultDownload(_ item: DownloadItem) {
        let work = {
            let itemID = item.id.uuidString
            guard item.isIPAVaultDownload, !item.isFinished, self.pausedIPAVaultDownloadIDs.contains(itemID) else { return }

            if self.ipavaultJobs[itemID] != nil {
                self.resumeRequestedIPAVaultDownloadIDs.insert(itemID)
            } else {
                self.pausedIPAVaultDownloadIDs.remove(itemID)
                self.setIPAVaultPausedState(itemID: itemID, isPaused: false)
            }

            self.pumpIPAVaultDownloadQueue()
            self.updateIPAVaultBackgroundTaskState()
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func setIPAVaultPausedState(itemID: String, isPaused: Bool) {
        guard let index = downloadItems.firstIndex(where: { $0.id.uuidString == itemID }) else { return }
        var item = downloadItems[index]
        item.isPaused = isPaused
        downloadItems[index] = item
    }

    private var runningIPAVaultDownloadCount: Int {
        activeIPAVaultDownloadIDs.reduce(into: 0) { count, itemID in
            if !pausedIPAVaultDownloadIDs.contains(itemID),
               !tunerSuspendedIPAVaultDownloadIDs.contains(itemID),
               ipavaultJobs[itemID]?.assembling != true {
                count += 1
            }
        }
    }

    private var transferringIPAVaultDownloadCount: Int {
        activeIPAVaultDownloadIDs.reduce(into: 0) { count, itemID in
            guard !pausedIPAVaultDownloadIDs.contains(itemID),
                  let job = ipavaultJobs[itemID],
                  !job.assembling,
                  !job.tasks.isEmpty else { return }
            count += 1
        }
    }

    func cancelDownload(_ item: DownloadItem) {
        let itemID = item.id.uuidString
        var handledByIPAVault = false

        let checkIPAVault = {
            handledByIPAVault = self.cancelIPAVaultDownloadIfPresent(itemID: itemID)
        }

        if Thread.isMainThread {
            checkIPAVault()
        } else {
            DispatchQueue.main.sync(execute: checkIPAVault)
        }

        if handledByIPAVault { return }

        urlSession.getAllTasks { tasks in
            if let task = tasks.first(where: { task in
                self.activeDownloads[task.taskIdentifier] == itemID
            }) {
                task.cancel()
            }
        }
    }

    private func cancelIPAVaultDownloadIfPresent(itemID: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))

        if let index = pendingIPAVaultDownloads.firstIndex(where: { $0.itemID == itemID }) {
            pendingIPAVaultDownloads.remove(at: index)
            downloadItems.removeAll { $0.id.uuidString == itemID }
            ipavaultActivityItemIDs.remove(itemID)
            completedIPAVaultActivityItemIDs.remove(itemID)
            pausedIPAVaultDownloadIDs.remove(itemID)
            resumeRequestedIPAVaultDownloadIDs.remove(itemID)
            pumpIPAVaultDownloadQueue()
            rebalanceIPAVaultStreams()
            updateIPAVaultBackgroundTaskState()
            return true
        }

        guard let job = ipavaultJobs.removeValue(forKey: itemID) else { return false }

        cancelIPAVaultStreams(job, requeueUnfinished: false)
        closeIPAVaultFileIfNeeded(job)
        activeIPAVaultDownloadIDs.remove(itemID)
        if ipavaultCurrentActivityItemID == itemID {
            ipavaultCurrentActivityItemID = nil
        }
        downloadItems.removeAll { $0.id.uuidString == itemID }
        ipavaultActivityItemIDs.remove(itemID)
        completedIPAVaultActivityItemIDs.remove(itemID)
        pausedIPAVaultDownloadIDs.remove(itemID)
        resumeRequestedIPAVaultDownloadIDs.remove(itemID)
        tunerSuspendedIPAVaultDownloadIDs.remove(itemID)
        try? FileManager.default.removeItem(at: job.directory)
        pumpIPAVaultDownloadQueue()
        rebalanceIPAVaultStreams()
        updateIPAVaultBackgroundTaskState()
        return true
    }

    private func pumpIPAVaultDownloadQueue() {
        dispatchPrecondition(condition: .onQueue(.main))

        while runningIPAVaultDownloadCount < maxConcurrentIPAVaultDownloads {
            if let itemID = resumeRequestedIPAVaultDownloadIDs.first {
                resumeRequestedIPAVaultDownloadIDs.remove(itemID)
                guard pausedIPAVaultDownloadIDs.contains(itemID), let job = ipavaultJobs[itemID] else {
                    continue
                }

                pausedIPAVaultDownloadIDs.remove(itemID)
                tunerSuspendedIPAVaultDownloadIDs.remove(itemID)
                setIPAVaultPausedState(itemID: itemID, isPaused: false)
                job.desiredStreams = ipavaultBatchTargetStreams
                rebalanceIPAVaultStreams()
                continue
            }

            if let itemID = tunerSuspendedIPAVaultDownloadIDs.first(where: { itemID in
                !pausedIPAVaultDownloadIDs.contains(itemID) &&
                    ipavaultJobs[itemID]?.assembling != true
            }), let job = ipavaultJobs[itemID] {
                tunerSuspendedIPAVaultDownloadIDs.remove(itemID)
                job.desiredStreams = ipavaultBatchTargetStreams
                rebalanceIPAVaultStreams()
                continue
            }

            guard let pendingIndex = pendingIPAVaultDownloads.firstIndex(where: {
                !pausedIPAVaultDownloadIDs.contains($0.itemID)
            }) else {
                break
            }

            let pending = pendingIPAVaultDownloads.remove(at: pendingIndex)
            guard downloadItems.contains(where: { $0.id.uuidString == pending.itemID && !$0.isFinished }) else {
                continue
            }
            startIPAVaultDownload(pending)
        }

        startIPAVaultAdaptiveControllerIfNeeded()
        rebalanceIPAVaultStreams()
    }

    private func startIPAVaultDownload(_ pending: PendingIPAVaultDownload) {
        let directory = ipavaultTransfersRootURL.appendingPathComponent(pending.itemID, isDirectory: true)
        let partialURL = directory.appendingPathComponent("download.partial", isDirectory: false)
        let fileManager = FileManager.default

        do {
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            guard fileManager.createFile(atPath: partialURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }

            let descriptor = Darwin.open(partialURL.path, O_RDWR)
            guard descriptor >= 0 else {
                throw posixError("open")
            }
            guard Darwin.ftruncate(descriptor, off_t(pending.totalBytes)) == 0 else {
                let error = posixError("ftruncate")
                Darwin.close(descriptor)
                throw error
            }

            let job = IPAVaultJob(
                itemID: pending.itemID,
                url: pending.url,
                totalBytes: pending.totalBytes,
                directory: directory,
                partialURL: partialURL,
                fileDescriptor: descriptor,
                startingStreams: ipavaultBatchTargetStreams
            )
            ipavaultJobs[pending.itemID] = job
            activeIPAVaultDownloadIDs.insert(pending.itemID)
            pausedIPAVaultDownloadIDs.remove(pending.itemID)
            setIPAVaultPausedState(itemID: pending.itemID, isPaused: false)
            updateIPAVaultBackgroundTaskState()
        } catch {
            try? fileManager.removeItem(at: directory)
            failIPAVaultDownload(itemID: pending.itemID, error: error)
        }
    }

    private func runningIPAVaultJobs() -> [IPAVaultJob] {
        activeIPAVaultDownloadIDs.compactMap { itemID in
            guard !pausedIPAVaultDownloadIDs.contains(itemID),
                  !tunerSuspendedIPAVaultDownloadIDs.contains(itemID),
                  let job = ipavaultJobs[itemID],
                  !job.assembling else { return nil }
            return job
        }
    }

    private func totalRunningIPAVaultStreamCount() -> Int {
        activeIPAVaultDownloadIDs.reduce(0) { partial, itemID in
            guard !pausedIPAVaultDownloadIDs.contains(itemID),
                  let job = ipavaultJobs[itemID],
                  !job.assembling else { return partial }
            return partial + job.tasks.count
        }
    }

    private var tunerIPAVaultDrainInProgress: Bool {
        tunerSuspendedIPAVaultDownloadIDs.contains { itemID in
            guard let job = ipavaultJobs[itemID], !job.assembling else { return false }
            return !job.tasks.isEmpty
        }
    }

    private var tunerIPAVaultStreamDrainInProgress: Bool {
        runningIPAVaultJobs().contains { job in
            job.tasks.count > ipavaultBatchTargetStreams
        }
    }

    private func rebalanceIPAVaultStreams() {
        dispatchPrecondition(condition: .onQueue(.main))

        let jobs = runningIPAVaultJobs()
        guard !jobs.isEmpty else {
            ipavaultAdaptiveStreamCount = 0
            return
        }

        for job in jobs {
            job.desiredStreams = min(ipavaultHardMaxStreamsPerFile, max(1, job.desiredStreams))

            var safety = 0
            while job.tasks.count < job.desiredStreams && safety < 128 {
                safety += 1

                if startNextIPAVaultLease(job) {
                    continue
                }

                // Near EOF all untouched ranges may already be leased. Split a long
                // active tail only when the Telegram-style ETA calculation says it
                // saves meaningful time; otherwise simply let the short lease finish.
                if !splitIPAVaultTailForAdditionalStream(in: [job]) {
                    break
                }
            }
        }

        ipavaultAdaptiveStreamCount = totalRunningIPAVaultStreamCount()
    }

    private func remainingIPAVaultBytes(_ job: IPAVaultJob) -> Int64 {
        max(0, job.totalBytes - job.committedBytes)
    }

    private func startNextIPAVaultLease(_ job: IPAVaultJob) -> Bool {
        guard !job.assembling, !pausedIPAVaultDownloadIDs.contains(job.itemID) else { return false }
        guard !job.freeRanges.isEmpty else { return false }

        job.freeRanges.sort { $0.start < $1.start }
        var source = job.freeRanges.removeFirst()
        guard source.length > 0 else { return false }

        let desiredLength = desiredIPAVaultLeaseLength(for: job)
        var leaseEnd = min(source.end, source.start + desiredLength)
        if leaseEnd < source.end {
            leaseEnd = alignIPAVaultOffsetDown(leaseEnd)
            if leaseEnd <= source.start {
                leaseEnd = min(source.end, source.start + ipavaultBlockSize)
            }
        }

        let lease = IPAVaultRange(start: source.start, end: leaseEnd, attempt: source.attempt)
        if leaseEnd < source.end {
            source.start = leaseEnd
            job.freeRanges.insert(source, at: 0)
        }

        var request = URLRequest(url: job.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        request.setValue("bytes=\(lease.start)-\(lease.end - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let task = ipavaultSession.dataTask(with: request)
        let now = ProcessInfo.processInfo.systemUptime
        let metadata = IPAVaultTaskMetadata(
            itemID: job.itemID,
            leaseStart: lease.start,
            requestEnd: lease.end,
            attempt: lease.attempt,
            startedAt: now
        )
        job.tasks[task.taskIdentifier] = task
        ipavaultTaskMetadata[task.taskIdentifier] = metadata
        task.countOfBytesClientExpectsToReceive = lease.length
        task.resume()
        return true
    }

    private func desiredIPAVaultLeaseLength(for job: IPAVaultJob) -> Int64 {
        let currentRates = job.tasks.keys.compactMap { taskID -> Double? in
            guard let metadata = ipavaultTaskMetadata[taskID] else { return nil }
            let rate = effectiveIPAVaultWorkerBPS(metadata, now: ProcessInfo.processInfo.systemUptime)
            return rate > 0 ? rate : nil
        }
        let historical = job.recentCompletedRates.suffix(12)
        let rates = Array(currentRates) + Array(historical)

        let estimate: Double
        if rates.isEmpty {
            estimate = Double(ipavaultDefaultLeaseBytes) / ipavaultLeaseTargetSeconds
        } else {
            estimate = median(rates)
        }

        let raw = Int64(max(1, estimate * ipavaultLeaseTargetSeconds))
        let clamped = min(ipavaultMaximumLeaseBytes, max(ipavaultMinimumLeaseBytes, raw))
        return max(ipavaultBlockSize, alignIPAVaultOffsetDown(clamped))
    }

    private func alignIPAVaultOffsetDown(_ value: Int64) -> Int64 {
        guard value > 0 else { return 0 }
        return (value / ipavaultBlockSize) * ipavaultBlockSize
    }

    private func alignIPAVaultOffsetNearest(_ value: Int64) -> Int64 {
        guard value > 0 else { return 0 }
        return ((value + ipavaultBlockSize / 2) / ipavaultBlockSize) * ipavaultBlockSize
    }

    private func splitIPAVaultTailForAdditionalStream(in jobs: [IPAVaultJob]) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        var candidates: [(eta: Double, metadata: IPAVaultTaskMetadata, job: IPAVaultJob, bps: Double)] = []
        var peerRates: [Double] = []

        for job in jobs {
            for taskID in job.tasks.keys {
                guard let metadata = ipavaultTaskMetadata[taskID], !metadata.preempted else { continue }
                let remaining = metadata.effectiveEnd - metadata.currentPosition
                let bps = effectiveIPAVaultWorkerBPS(metadata, now: now)
                if bps > 0 { peerRates.append(bps) }
                guard remaining >= ipavaultTailMinimumBytes * 2 else { continue }
                candidates.append((Double(remaining) / max(1, bps), metadata, job, bps))
            }
        }

        guard !candidates.isEmpty, !peerRates.isEmpty else { return false }
        let medianBPS = median(peerRates)
        guard let victim = candidates.max(by: { $0.eta < $1.eta }) else { return false }

        let victimBPS = victim.bps > 0 ? victim.bps : max(1, medianBPS * 0.25)
        let thiefBPS = max(1, medianBPS)
        let position = victim.metadata.currentPosition
        let oldEnd = victim.metadata.effectiveEnd
        let remaining = oldEnd - position
        guard remaining >= ipavaultTailMinimumBytes * 2 else { return false }

        let keepBytes = Int64(Double(remaining) * (victimBPS / (victimBPS + thiefBPS)))
        var cut = alignIPAVaultOffsetNearest(position + keepBytes)
        cut = max(position + ipavaultTailMinimumBytes, min(cut, oldEnd - ipavaultTailMinimumBytes))
        cut = alignIPAVaultOffsetDown(cut)
        guard cut > position, cut < oldEnd else { return false }

        let victimKeep = Double(cut - position) / victimBPS
        let thiefTime = Double(oldEnd - cut) / thiefBPS
        let projectedNewTime = max(victimKeep, thiefTime)
        let projectedSaving = victim.eta - projectedNewTime
        guard projectedSaving >= ipavaultTailMinimumSavingsSeconds else { return false }

        victim.metadata.effectiveEnd = cut
        victim.metadata.preempted = true
        victim.job.freeRanges.append(
            IPAVaultRange(start: cut, end: oldEnd, attempt: victim.metadata.attempt)
        )
        print(
            "IPA Vault adaptive: split \(oldEnd - cut) bytes from a straggler " +
            "(projected save \(String(format: "%.2f", projectedSaving))s)."
        )
        return true
    }

    private func updateIPAVaultProgress(for job: IPAVaultJob) {
        guard let index = downloadItems.firstIndex(where: { $0.id.uuidString == job.itemID }) else { return }

        let uncommittedInFlight = job.tasks.keys.reduce(Int64(0)) { partial, taskID in
            guard let metadata = ipavaultTaskMetadata[taskID] else { return partial }
            return partial + max(0, metadata.currentPosition - metadata.committedEnd)
        }
        let downloaded = min(job.totalBytes, max(0, job.committedBytes + uncommittedInFlight))

        var item = downloadItems[index]
        item.totalBytes = job.totalBytes
        item.bytesDownloaded = downloaded
        item.progress = job.totalBytes > 0 ? Double(downloaded) / Double(job.totalBytes) : 0
        downloadItems[index] = item
        publishIPAVaultBackgroundTaskState()
    }

    private func commitIPAVaultBytes(_ metadata: IPAVaultTaskMetadata, job: IPAVaultJob, through absoluteEnd: Int64) {
        let bounded = min(metadata.effectiveEnd, max(metadata.committedEnd, absoluteEnd))
        let commitEnd: Int64
        if bounded == metadata.effectiveEnd && metadata.effectiveEnd == job.totalBytes {
            commitEnd = bounded
        } else {
            commitEnd = alignIPAVaultOffsetDown(bounded)
        }

        guard commitEnd > metadata.committedEnd else { return }
        job.committedBytes += commitEnd - metadata.committedEnd
        metadata.committedEnd = commitEnd
    }

    private func completeIPAVaultStream(taskIdentifier: Int, error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let metadata = ipavaultTaskMetadata[taskIdentifier],
              let job = ipavaultJobs[metadata.itemID] else { return }

        job.tasks.removeValue(forKey: taskIdentifier)
        ipavaultTaskMetadata.removeValue(forKey: taskIdentifier)

        if let terminalError = metadata.terminalError {
            failIPAVaultDownload(itemID: metadata.itemID, error: terminalError)
            return
        }

        let reachedEffectiveEnd = metadata.currentPosition >= metadata.effectiveEnd
        let cancellationWasExpected = metadata.preempted && reachedEffectiveEnd

        if error == nil || cancellationWasExpected {
            guard reachedEffectiveEnd else {
                requeueIPAVaultStream(metadata, job: job, reason: error)
                return
            }

            if metadata.committedEnd < metadata.effectiveEnd {
                job.committedBytes += metadata.effectiveEnd - metadata.committedEnd
                metadata.committedEnd = metadata.effectiveEnd
            }

            let elapsed = max(0.001, ProcessInfo.processInfo.systemUptime - metadata.startedAt)
            let completedLength = max(0, metadata.effectiveEnd - metadata.leaseStart)
            if completedLength > 0 {
                job.recentCompletedRates.append(Double(completedLength) / elapsed)
                if job.recentCompletedRates.count > 24 {
                    job.recentCompletedRates.removeFirst(job.recentCompletedRates.count - 24)
                }
            }

            updateIPAVaultProgress(for: job)
            maybeFinishIPAVaultDownload(job)
            rebalanceIPAVaultStreams()
            return
        }

        requeueIPAVaultStream(metadata, job: job, reason: error)
    }

    private func requeueIPAVaultStream(_ metadata: IPAVaultTaskMetadata, job: IPAVaultJob, reason: Error?) {
        let retryStart = metadata.committedEnd
        guard retryStart < metadata.effectiveEnd else {
            maybeFinishIPAVaultDownload(job)
            rebalanceIPAVaultStreams()
            return
        }

        let nextAttempt = metadata.attempt + 1
        if nextAttempt > ipavaultMaximumRangeRetries {
            let detail = reason?.localizedDescription ?? "range ended before all committed bytes arrived"
            failIPAVaultDownload(
                itemID: job.itemID,
                error: NSError(
                    domain: "IPAVault",
                    code: 31,
                    userInfo: [NSLocalizedDescriptionKey: "A ranged download repeatedly failed near byte \(retryStart): \(detail)"]
                )
            )
            return
        }

        job.freeRanges.append(
            IPAVaultRange(start: retryStart, end: metadata.effectiveEnd, attempt: nextAttempt)
        )
        updateIPAVaultProgress(for: job)
        rebalanceIPAVaultStreams()
    }

    private func cancelIPAVaultStreams(_ job: IPAVaultJob, requeueUnfinished: Bool) {
        let taskIDs = Array(job.tasks.keys)
        for taskID in taskIDs {
            guard let task = job.tasks.removeValue(forKey: taskID),
                  let metadata = ipavaultTaskMetadata.removeValue(forKey: taskID) else {
                continue
            }

            if requeueUnfinished, metadata.committedEnd < metadata.effectiveEnd {
                job.freeRanges.append(
                    IPAVaultRange(
                        start: metadata.committedEnd,
                        end: metadata.effectiveEnd,
                        attempt: metadata.attempt
                    )
                )
            }
            metadata.suppressCompletion = true
            task.cancel()
        }
        updateIPAVaultProgress(for: job)
    }

    private func maybeFinishIPAVaultDownload(_ job: IPAVaultJob) {
        guard !job.assembling,
              job.tasks.isEmpty,
              job.freeRanges.isEmpty,
              job.committedBytes >= job.totalBytes else { return }

        job.assembling = true
        updateIPAVaultProgress(for: job)
        updateIPAVaultBackgroundTaskState()

        let itemID = job.itemID
        let partialURL = job.partialURL
        let descriptor = job.fileDescriptor
        job.fileDescriptor = -1

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let result: Result<URL, Error>
            if descriptor >= 0 && Darwin.fsync(descriptor) != 0 {
                let error = self.posixError("fsync")
                Darwin.close(descriptor)
                result = .failure(error)
            } else {
                if descriptor >= 0 {
                    Darwin.close(descriptor)
                }
                let finalSize = self.fileSize(at: partialURL)
                if finalSize == job.totalBytes {
                    result = .success(partialURL)
                } else {
                    result = .failure(
                        NSError(
                            domain: "IPAVault",
                            code: 32,
                            userInfo: [NSLocalizedDescriptionKey: "The completed IPA has an unexpected size (\(finalSize) of \(job.totalBytes) bytes)."]
                        )
                    )
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.finishIPAVaultDownload(itemID: itemID, result: result)
            }
        }
    }

    private func finishIPAVaultDownload(itemID: String, result: Result<URL, Error>) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let job = ipavaultJobs[itemID] else {
            if case .success(let temporaryURL) = result {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            return
        }

        switch result {
        case .failure(let error):
            failIPAVaultDownload(itemID: itemID, error: error)

        case .success(let temporaryURL):
            guard let index = downloadItems.firstIndex(where: { $0.id.uuidString == itemID }) else {
                failIPAVaultDownload(
                    itemID: itemID,
                    error: NSError(domain: "IPAVault", code: 33, userInfo: [NSLocalizedDescriptionKey: "The download item disappeared before the completed IPA could be moved."])
                )
                return
            }

            let destination = downloadItems[index].localPath
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)

                var item = downloadItems[index]
                item.url = destination
                item.isFinished = true
                item.progress = 1
                item.totalBytes = job.totalBytes
                item.bytesDownloaded = job.totalBytes
                downloadItems[index] = item

                completedIPAVaultActivityItemIDs.insert(itemID)
                if ipavaultCurrentActivityItemID == itemID {
                    ipavaultCurrentActivityItemID = nil
                }
                ipavaultJobs.removeValue(forKey: itemID)
                activeIPAVaultDownloadIDs.remove(itemID)
                pausedIPAVaultDownloadIDs.remove(itemID)
                resumeRequestedIPAVaultDownloadIDs.remove(itemID)
                tunerSuspendedIPAVaultDownloadIDs.remove(itemID)
                try? FileManager.default.removeItem(at: job.directory)
                pumpIPAVaultDownloadQueue()
                updateIPAVaultBackgroundTaskState()
            } catch {
                failIPAVaultDownload(itemID: itemID, error: error)
            }
        }
    }

    private func failIPAVaultDownload(itemID: String, error: Error) {
        dispatchPrecondition(condition: .onQueue(.main))
        print("IPA Vault download failed: \(error.localizedDescription)")

        if let job = ipavaultJobs.removeValue(forKey: itemID) {
            cancelIPAVaultStreams(job, requeueUnfinished: false)
            closeIPAVaultFileIfNeeded(job)
            try? FileManager.default.removeItem(at: job.directory)
        }

        activeIPAVaultDownloadIDs.remove(itemID)
        downloadItems.removeAll { $0.id.uuidString == itemID }
        ipavaultActivityItemIDs.remove(itemID)
        completedIPAVaultActivityItemIDs.remove(itemID)
        pausedIPAVaultDownloadIDs.remove(itemID)
        resumeRequestedIPAVaultDownloadIDs.remove(itemID)
        tunerSuspendedIPAVaultDownloadIDs.remove(itemID)
        pumpIPAVaultDownloadQueue()
        updateIPAVaultBackgroundTaskState()
    }

    private func closeIPAVaultFileIfNeeded(_ job: IPAVaultJob) {
        if job.fileDescriptor >= 0 {
            Darwin.close(job.fileDescriptor)
            job.fileDescriptor = -1
        }
    }

    private func writeIPAVaultData(_ data: Data, count: Int, to descriptor: Int32, offset: Int64) throws {
        guard count > 0 else { return }

        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < count {
                let result = Darwin.pwrite(
                    descriptor,
                    base.advanced(by: written),
                    count - written,
                    off_t(offset + Int64(written))
                )
                if result < 0 {
                    throw posixError("pwrite")
                }
                if result == 0 {
                    throw NSError(domain: "IPAVault", code: 34, userInfo: [NSLocalizedDescriptionKey: "Writing the IPA made no progress."])
                }
                written += result
            }
        }
    }

    private func posixError(_ operation: String) -> NSError {
        let code = errno
        let description = String(cString: strerror(code))
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "IPA Vault \(operation) failed: \(description)"]
        )
    }

    private func parseIPAVaultContentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let body = trimmed.dropFirst(6)
        let pieces = body.split(separator: "/", maxSplits: 1)
        guard pieces.count == 2, let total = Int64(pieces[1]) else { return nil }
        let bounds = pieces[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]) else { return nil }
        return (start, end, total)
    }

    // MARK: Batch adaptive controller

    private func beginIPAVaultBatch() {
        let now = ProcessInfo.processInfo.systemUptime
        BackgroundTaskManager.shared.clearReport(.ipaVaultDownloads)
        ipavaultBackgroundTaskSnapshot = nil
        ipavaultBatchIsActive = true
        ipavaultBatchTargetConcurrency = 1
        ipavaultBatchTargetStreams = ipavaultBatchInitialStreamsPerFile
        maxConcurrentIPAVaultDownloads = 1
        ipavaultBatchTuningPhase = .concurrency
        ipavaultBatchProbe = nil
        ipavaultBatchControllerThroughputSamples.removeAll(keepingCapacity: true)
        ipavaultBatchConcurrencyUpperBound = nil
        ipavaultBatchStreamsUpperBound = nil
        ipavaultBatchLastDecisionAt = now
        ipavaultBatchLastStableBPS = 0
        ipavaultBatchNextSteadyProbeAt = 0
        ipavaultBatchSteadyProbeStep = 0
        tunerSuspendedIPAVaultDownloadIDs.removeAll(keepingCapacity: true)
        ipavaultTotalUsefulBytes = 0
        ipavaultAggregateRateSamples.removeAll(keepingCapacity: true)
        ipavaultAdaptiveConcurrentCount = 1
        ipavaultAdaptiveStreamsPerFile = ipavaultBatchInitialStreamsPerFile
        ipavaultAdaptiveStatus = "Tuning concurrency"
        print("IPA Vault adaptive: new batch starts at 1 file × 2 streams.")
    }

    private func endIPAVaultBatch() {
        guard ipavaultBatchIsActive else { return }
        print(
            "IPA Vault adaptive: batch ended at \(ipavaultBatchTargetConcurrency) file(s) × " +
            "\(ipavaultBatchTargetStreams) streams; discard all learned state."
        )
        ipavaultBatchIsActive = false
        ipavaultBatchTargetConcurrency = 1
        ipavaultBatchTargetStreams = ipavaultBatchInitialStreamsPerFile
        maxConcurrentIPAVaultDownloads = 1
        ipavaultBatchTuningPhase = .concurrency
        ipavaultBatchProbe = nil
        ipavaultBatchControllerThroughputSamples.removeAll(keepingCapacity: true)
        ipavaultBatchConcurrencyUpperBound = nil
        ipavaultBatchStreamsUpperBound = nil
        ipavaultBatchLastDecisionAt = 0
        ipavaultBatchLastStableBPS = 0
        ipavaultBatchNextSteadyProbeAt = 0
        ipavaultBatchSteadyProbeStep = 0
        tunerSuspendedIPAVaultDownloadIDs.removeAll(keepingCapacity: true)
        ipavaultAdaptiveConcurrentCount = 0
        ipavaultAdaptiveStreamsPerFile = ipavaultBatchInitialStreamsPerFile
        ipavaultAdaptiveStatus = "Idle"
    }

    private func recordIPAVaultUsefulBytes(_ bytes: Int64, now: TimeInterval) {
        guard bytes > 0 else { return }

        ipavaultTotalUsefulBytes += bytes
        if let last = ipavaultAggregateRateSamples.last, now - last.time < 0.10 {
            ipavaultAggregateRateSamples[ipavaultAggregateRateSamples.count - 1] = IPAVaultAggregateSample(
                time: now,
                bytes: ipavaultTotalUsefulBytes
            )
        } else {
            ipavaultAggregateRateSamples.append(IPAVaultAggregateSample(time: now, bytes: ipavaultTotalUsefulBytes))
        }
        let aggregateCutoff = now - 6.0
        while ipavaultAggregateRateSamples.count > 2, ipavaultAggregateRateSamples[1].time < aggregateCutoff {
            ipavaultAggregateRateSamples.removeFirst()
        }
    }

    private func currentIPAVaultBPS(samples: [IPAVaultAggregateSample], now: TimeInterval) -> Double {
        let cutoff = now - ipavaultSpeedWindowSeconds
        guard let last = samples.last else { return 0 }
        guard now - last.time <= 1.0 else { return 0 }
        let first = samples.last(where: { $0.time <= cutoff }) ?? samples.first!
        let span = last.time - first.time
        guard span >= 0.50 else { return 0 }
        return Double(max(0, last.bytes - first.bytes)) / span
    }

    private func currentIPAVaultAggregateBPS(now: TimeInterval) -> Double {
        currentIPAVaultBPS(samples: ipavaultAggregateRateSamples, now: now)
    }

    private func availableIPAVaultBatchConcurrency() -> Int {
        let active = activeIPAVaultDownloadIDs.reduce(into: 0) { count, itemID in
            if !pausedIPAVaultDownloadIDs.contains(itemID), ipavaultJobs[itemID]?.assembling != true {
                count += 1
            }
        }
        let pending = pendingIPAVaultDownloads.reduce(into: 0) { count, pending in
            if !pausedIPAVaultDownloadIDs.contains(pending.itemID) {
                count += 1
            }
        }
        return min(ipavaultHardMaxConcurrentDownloads, max(1, active + pending))
    }

    private func setIPAVaultBatchConcurrency(_ requested: Int) {
        let target = min(availableIPAVaultBatchConcurrency(), max(1, requested))
        let current = runningIPAVaultDownloadCount

        if target < current {
            let victims = runningIPAVaultJobs()
                .sorted { lhs, rhs in
                    let lhsFraction = lhs.totalBytes > 0 ? Double(lhs.committedBytes) / Double(lhs.totalBytes) : 0
                    let rhsFraction = rhs.totalBytes > 0 ? Double(rhs.committedBytes) / Double(rhs.totalBytes) : 0
                    if lhsFraction == rhsFraction {
                        return lhs.itemID < rhs.itemID
                    }
                    // Keep the most-complete jobs active so slots turn over quickly.
                    return lhsFraction < rhsFraction
                }
                .prefix(current - target)

            for job in victims {
                tunerSuspendedIPAVaultDownloadIDs.insert(job.itemID)
            }
        }

        ipavaultBatchTargetConcurrency = target
        maxConcurrentIPAVaultDownloads = target
        ipavaultAdaptiveConcurrentCount = target

        if target > current {
            pumpIPAVaultDownloadQueue()
        } else {
            rebalanceIPAVaultStreams()
        }
    }

    private func setIPAVaultBatchStreams(_ requested: Int) {
        let target = min(ipavaultHardMaxStreamsPerFile, max(1, requested))
        ipavaultBatchTargetStreams = target
        ipavaultAdaptiveStreamsPerFile = target

        for job in runningIPAVaultJobs() {
            job.desiredStreams = target
        }
        rebalanceIPAVaultStreams()
    }

    private func nextIPAVaultConcurrencySearchTarget() -> Int? {
        let current = ipavaultBatchTargetConcurrency
        let maximum = availableIPAVaultBatchConcurrency()
        guard current < maximum else { return nil }

        if let upper = ipavaultBatchConcurrencyUpperBound {
            let boundedUpper = min(upper, maximum + 1)
            guard boundedUpper - current > 1 else { return nil }
            return current + (boundedUpper - current) / 2
        }

        if current == 1 {
            return min(maximum, 2)
        }
        return min(maximum, current * 2)
    }

    private func nextIPAVaultStreamSearchTarget() -> Int? {
        let current = ipavaultBatchTargetStreams
        guard current < ipavaultHardMaxStreamsPerFile else { return nil }

        if let upper = ipavaultBatchStreamsUpperBound {
            guard upper - current > 1 else { return nil }
            return current + (upper - current) / 2
        }

        if current <= 2 {
            return min(ipavaultHardMaxStreamsPerFile, 4)
        }
        if current <= 4 {
            return min(ipavaultHardMaxStreamsPerFile, 8)
        }
        return ipavaultHardMaxStreamsPerFile
    }

    private func advanceIPAVaultTuningToStreams(now: TimeInterval) {
        ipavaultBatchTuningPhase = .streams
        ipavaultBatchStreamsUpperBound = nil
        ipavaultBatchControllerThroughputSamples.removeAll(keepingCapacity: true)
        ipavaultBatchLastDecisionAt = now
        ipavaultAdaptiveStatus = "Tuning streams"
        print(
            "IPA Vault adaptive: concurrency settled at \(ipavaultBatchTargetConcurrency); " +
            "tuning streams from \(ipavaultBatchTargetStreams)."
        )
    }

    private func advanceIPAVaultTuningToSteady(now: TimeInterval) {
        ipavaultBatchTuningPhase = .steady
        ipavaultBatchControllerThroughputSamples.removeAll(keepingCapacity: true)
        ipavaultBatchLastDecisionAt = now
        ipavaultBatchNextSteadyProbeAt = now + ipavaultSteadyRetuneSeconds
        ipavaultAdaptiveStatus = "Optimized"
        print(
            "IPA Vault adaptive: optimized at \(ipavaultBatchTargetConcurrency) file(s) × " +
            "\(ipavaultBatchTargetStreams) streams."
        )
    }

    private func startIPAVaultAdaptiveControllerIfNeeded() {
        guard ipavaultAdaptiveTimer == nil, ipavaultBatchIsActive else { return }
        let timer = Timer(timeInterval: ipavaultControllerTickSeconds, repeats: true) { [weak self] _ in
            self?.tickIPAVaultAdaptiveController()
        }
        RunLoop.main.add(timer, forMode: .common)
        ipavaultAdaptiveTimer = timer
        tickIPAVaultAdaptiveController()
    }

    private func stopIPAVaultAdaptiveController() {
        ipavaultAdaptiveTimer?.invalidate()
        ipavaultAdaptiveTimer = nil
        ipavaultAdaptiveConcurrentCount = 0
        ipavaultAdaptiveStreamCount = 0
        ipavaultAdaptiveSpeedBPS = 0
        ipavaultAdaptiveStatus = "Idle"
        ipavaultAggregateRateSamples.removeAll()
        ipavaultBatchControllerThroughputSamples.removeAll()
        ipavaultBatchProbe = nil
    }

    private func tickIPAVaultAdaptiveController() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard ipavaultBatchIsActive else { return }

        let now = ProcessInfo.processInfo.systemUptime
        recycleStalledIPAVaultStreams(now: now)
        rebalanceIPAVaultStreams()

        ipavaultAdaptiveConcurrentCount = min(ipavaultBatchTargetConcurrency, availableIPAVaultBatchConcurrency())
        ipavaultAdaptiveStreamsPerFile = ipavaultBatchTargetStreams
        ipavaultAdaptiveStreamCount = totalRunningIPAVaultStreamCount()
        let aggregateBPS = currentIPAVaultAggregateBPS(now: now)
        ipavaultAdaptiveSpeedBPS = aggregateBPS

        guard aggregateBPS > 0 else { return }

        ipavaultBatchControllerThroughputSamples.append((time: now, bps: aggregateBPS))
        let cutoff = now - 8.0
        ipavaultBatchControllerThroughputSamples.removeAll { $0.time < cutoff }

        if let probe = ipavaultBatchProbe {
            continueIPAVaultBatchProbe(probe, now: now, currentBPS: aggregateBPS)
            return
        }

        // A rejected/downward probe may leave already-issued leases draining for a
        // moment. Do not treat those bytes as the baseline for the restored target.
        if tunerIPAVaultDrainInProgress || tunerIPAVaultStreamDrainInProgress {
            ipavaultBatchControllerThroughputSamples.removeAll(keepingCapacity: true)
            return
        }

        guard now - ipavaultBatchLastDecisionAt >= 0.75 else { return }
        let baselineSamples = ipavaultBatchControllerThroughputSamples.suffix(5).map(\.bps)
        guard baselineSamples.count >= 3 else { return }

        let baseline = median(Array(baselineSamples))
        let noise = relativeNoise(Array(baselineSamples), around: baseline)
        if ipavaultBatchLastStableBPS <= 0 {
            ipavaultBatchLastStableBPS = baseline
        }

        switch ipavaultBatchTuningPhase {
        case .concurrency:
            if availableIPAVaultBatchConcurrency() <= ipavaultBatchTargetConcurrency {
                advanceIPAVaultTuningToStreams(now: now)
                return
            }
            guard let target = nextIPAVaultConcurrencySearchTarget() else {
                advanceIPAVaultTuningToStreams(now: now)
                return
            }
            beginIPAVaultBatchProbe(
                dimension: .concurrency,
                targetValue: target,
                baselineBPS: baseline,
                noiseFraction: noise,
                now: now,
                isSteadyProbe: false
            )

        case .streams:
            guard let target = nextIPAVaultStreamSearchTarget() else {
                advanceIPAVaultTuningToSteady(now: now)
                return
            }
            beginIPAVaultBatchProbe(
                dimension: .streams,
                targetValue: target,
                baselineBPS: baseline,
                noiseFraction: noise,
                now: now,
                isSteadyProbe: false
            )

        case .steady:
            let sharpRegression = ipavaultBatchLastStableBPS > 0 && baseline < ipavaultBatchLastStableBPS * 0.75
            guard sharpRegression || now >= ipavaultBatchNextSteadyProbeAt else { return }
            beginNextIPAVaultSteadyProbe(
                baselineBPS: baseline,
                noiseFraction: noise,
                now: now
            )
        }
    }

    private func beginNextIPAVaultSteadyProbe(
        baselineBPS: Double,
        noiseFraction: Double,
        now: TimeInterval
    ) {
        for _ in 0..<4 {
            let step = ipavaultBatchSteadyProbeStep % 4
            ipavaultBatchSteadyProbeStep = (ipavaultBatchSteadyProbeStep + 1) % 4

            switch step {
            case 0 where ipavaultBatchTargetConcurrency > 1:
                beginIPAVaultBatchProbe(
                    dimension: .concurrency,
                    targetValue: ipavaultBatchTargetConcurrency - 1,
                    baselineBPS: baselineBPS,
                    noiseFraction: noiseFraction,
                    now: now,
                    isSteadyProbe: true
                )
                return

            case 1 where ipavaultBatchTargetStreams > 1:
                beginIPAVaultBatchProbe(
                    dimension: .streams,
                    targetValue: ipavaultBatchTargetStreams - 1,
                    baselineBPS: baselineBPS,
                    noiseFraction: noiseFraction,
                    now: now,
                    isSteadyProbe: true
                )
                return

            case 2 where ipavaultBatchTargetConcurrency < availableIPAVaultBatchConcurrency():
                beginIPAVaultBatchProbe(
                    dimension: .concurrency,
                    targetValue: ipavaultBatchTargetConcurrency + 1,
                    baselineBPS: baselineBPS,
                    noiseFraction: noiseFraction,
                    now: now,
                    isSteadyProbe: true
                )
                return

            case 3 where ipavaultBatchTargetStreams < ipavaultHardMaxStreamsPerFile:
                beginIPAVaultBatchProbe(
                    dimension: .streams,
                    targetValue: ipavaultBatchTargetStreams + 1,
                    baselineBPS: baselineBPS,
                    noiseFraction: noiseFraction,
                    now: now,
                    isSteadyProbe: true
                )
                return

            default:
                continue
            }
        }

        ipavaultBatchNextSteadyProbeAt = now + ipavaultSteadyRetuneSeconds
    }

    private func beginIPAVaultBatchProbe(
        dimension: IPAVaultBatchProbeDimension,
        targetValue: Int,
        baselineBPS: Double,
        noiseFraction: Double,
        now: TimeInterval,
        isSteadyProbe: Bool
    ) {
        let previous: Int
        switch dimension {
        case .concurrency:
            previous = ipavaultBatchTargetConcurrency
        case .streams:
            previous = ipavaultBatchTargetStreams
        }
        guard previous != targetValue else { return }

        ipavaultBatchProbe = IPAVaultBatchAdaptiveProbe(
            dimension: dimension,
            previousValue: previous,
            targetValue: targetValue,
            baselineBPS: baselineBPS,
            noiseFraction: noiseFraction,
            requestedAt: now,
            isSteadyProbe: isSteadyProbe
        )
        if isSteadyProbe {
            ipavaultAdaptiveStatus = "Retuning"
        }

        let dimensionLabel = dimension == .concurrency ? "files" : "streams"
        print(
            "IPA Vault adaptive: probe \(dimensionLabel) \(previous)→\(targetValue) from " +
            "\(String(format: "%.1f", baselineBPS / 1_000_000)) MB/s aggregate."
        )

        switch dimension {
        case .concurrency:
            setIPAVaultBatchConcurrency(targetValue)
        case .streams:
            setIPAVaultBatchStreams(targetValue)
        }
        ipavaultBatchLastDecisionAt = now
    }

    private func ipavaultBatchProbeTargetReached(_ probe: IPAVaultBatchAdaptiveProbe) -> Bool {
        switch probe.dimension {
        case .concurrency:
            if probe.targetValue > probe.previousValue {
                return runningIPAVaultDownloadCount >= probe.targetValue &&
                    transferringIPAVaultDownloadCount >= probe.targetValue
            }
            return runningIPAVaultDownloadCount <= probe.targetValue &&
                transferringIPAVaultDownloadCount <= probe.targetValue

        case .streams:
            let jobs = runningIPAVaultJobs()
            guard !jobs.isEmpty else { return false }
            if probe.targetValue > probe.previousValue {
                return jobs.allSatisfy { $0.tasks.count >= probe.targetValue }
            }
            return jobs.allSatisfy { $0.tasks.count <= probe.targetValue }
        }
    }

    private func continueIPAVaultBatchProbe(
        _ probe: IPAVaultBatchAdaptiveProbe,
        now: TimeInterval,
        currentBPS: Double
    ) {
        if probe.dimension == .concurrency,
           probe.targetValue > probe.previousValue,
           availableIPAVaultBatchConcurrency() < probe.targetValue {
            finishIPAVaultBatchProbe(probe, keepTarget: false, measuredBPS: probe.baselineBPS, now: now)
            return
        }

        guard ipavaultBatchProbeTargetReached(probe) else {
            if now - probe.requestedAt > 8.0 {
                finishIPAVaultBatchProbe(probe, keepTarget: false, measuredBPS: probe.baselineBPS, now: now)
            }
            return
        }

        if probe.measurementStartedAt == nil {
            probe.measurementStartedAt = now
            probe.samples.removeAll()
            return
        }

        guard let measurementStartedAt = probe.measurementStartedAt else { return }
        if now - measurementStartedAt < ipavaultProbeSettleSeconds {
            return
        }

        probe.samples.append(currentBPS)
        guard now - measurementStartedAt >= ipavaultProbeSettleSeconds + ipavaultProbeMeasureSeconds,
              probe.samples.count >= 2 else { return }

        let measured = median(probe.samples)
        let movingUp = probe.targetValue > probe.previousValue
        let keepTarget: Bool
        if movingUp {
            let requiredGain = max(0.03, min(0.10, probe.noiseFraction * 1.25 + 0.015))
            keepTarget = measured >= probe.baselineBPS * (1.0 + requiredGain)
        } else {
            let toleratedLoss = min(0.03, max(0.015, probe.noiseFraction))
            keepTarget = measured >= probe.baselineBPS * (1.0 - toleratedLoss)
        }

        finishIPAVaultBatchProbe(probe, keepTarget: keepTarget, measuredBPS: measured, now: now)
    }

    private func finishIPAVaultBatchProbe(
        _ probe: IPAVaultBatchAdaptiveProbe,
        keepTarget: Bool,
        measuredBPS: Double,
        now: TimeInterval
    ) {
        if !keepTarget {
            switch probe.dimension {
            case .concurrency:
                setIPAVaultBatchConcurrency(probe.previousValue)
            case .streams:
                setIPAVaultBatchStreams(probe.previousValue)
            }
        }

        if !probe.isSteadyProbe {
            switch probe.dimension {
            case .concurrency:
                if !keepTarget && probe.targetValue > probe.previousValue {
                    ipavaultBatchConcurrencyUpperBound = probe.targetValue
                }
            case .streams:
                if !keepTarget && probe.targetValue > probe.previousValue {
                    ipavaultBatchStreamsUpperBound = probe.targetValue
                }
            }
        }

        ipavaultBatchLastStableBPS = keepTarget ? measuredBPS : probe.baselineBPS
        let resultLabel = keepTarget ? "keep" : "revert"
        let dimensionLabel = probe.dimension == .concurrency ? "files" : "streams"
        print(
            "IPA Vault adaptive: \(resultLabel) \(probe.targetValue) \(dimensionLabel); baseline " +
            "\(String(format: "%.1f", probe.baselineBPS / 1_000_000)) MB/s, measured " +
            "\(String(format: "%.1f", measuredBPS / 1_000_000)) MB/s aggregate."
        )

        ipavaultBatchProbe = nil
        ipavaultBatchControllerThroughputSamples.removeAll(keepingCapacity: true)
        if keepTarget && !probe.isSteadyProbe {
            // The probe samples were already collected entirely at the accepted
            // target, so reuse them as the next baseline instead of idling for a
            // second warm-up window between successful coarse-search steps.
            let retained = Array(probe.samples.suffix(5))
            for (index, bps) in retained.enumerated() {
                let age = Double(retained.count - index - 1) * ipavaultControllerTickSeconds
                ipavaultBatchControllerThroughputSamples.append((time: now - age, bps: bps))
            }
        }
        ipavaultBatchLastDecisionAt = now

        if probe.isSteadyProbe {
            ipavaultBatchNextSteadyProbeAt = now + ipavaultSteadyRetuneSeconds
            ipavaultAdaptiveStatus = "Optimized"
        }
    }

    private func recycleStalledIPAVaultStreams(now: TimeInterval) {
        let jobs = activeIPAVaultDownloadIDs.compactMap { itemID -> IPAVaultJob? in
            guard !pausedIPAVaultDownloadIDs.contains(itemID),
                  let job = ipavaultJobs[itemID],
                  !job.assembling else { return nil }
            return job
        }
        var candidates: [(taskID: Int, metadata: IPAVaultTaskMetadata, job: IPAVaultJob)] = []
        var healthyRates: [Double] = []

        for job in jobs {
            for taskID in job.tasks.keys {
                guard let metadata = ipavaultTaskMetadata[taskID] else { continue }
                let rate = effectiveIPAVaultWorkerBPS(metadata, now: now)
                let staleFor = now - metadata.lastProgressAt
                if rate > 0, staleFor < 1.5 {
                    healthyRates.append(rate)
                }
                if now - metadata.startedAt >= ipavaultStallDetectionFloorSeconds,
                   staleFor >= ipavaultWorkerStallSeconds {
                    candidates.append((taskID, metadata, job))
                }
            }
        }

        guard !candidates.isEmpty, !healthyRates.isEmpty else { return }
        let peerMedian = median(healthyRates)
        guard peerMedian >= 256 * 1024 else { return }

        // Recycle at most one stream per controller tick. That avoids a transient
        // radio/server hiccup causing a synchronized restart storm.
        if let stalled = candidates.max(by: {
            (now - $0.metadata.lastProgressAt) < (now - $1.metadata.lastProgressAt)
        }) {
            let nextAttempt = stalled.metadata.attempt + 1
            if nextAttempt > ipavaultMaximumRangeRetries {
                failIPAVaultDownload(
                    itemID: stalled.job.itemID,
                    error: NSError(
                        domain: "IPAVault",
                        code: 37,
                        userInfo: [NSLocalizedDescriptionKey: "A ranged stream repeatedly stalled near byte \(stalled.metadata.committedEnd)."]
                    )
                )
                return
            }

            guard let task = stalled.job.tasks.removeValue(forKey: stalled.taskID) else { return }
            ipavaultTaskMetadata.removeValue(forKey: stalled.taskID)
            if stalled.metadata.committedEnd < stalled.metadata.effectiveEnd {
                stalled.job.freeRanges.append(
                    IPAVaultRange(
                        start: stalled.metadata.committedEnd,
                        end: stalled.metadata.effectiveEnd,
                        attempt: nextAttempt
                    )
                )
            }
            print(
                "IPA Vault adaptive: recycling stalled stream at byte \(stalled.metadata.committedEnd)."
            )
            stalled.metadata.suppressCompletion = true
            task.cancel()
            updateIPAVaultProgress(for: stalled.job)
            rebalanceIPAVaultStreams()
        }
    }

    private func effectiveIPAVaultWorkerBPS(_ metadata: IPAVaultTaskMetadata, now: TimeInterval) -> Double {
        let progressed = max(0, metadata.currentPosition - metadata.leaseStart)
        let elapsed = max(0.001, now - metadata.startedAt)
        let average = Double(progressed) / elapsed

        let cutoff = now - ipavaultSpeedWindowSeconds
        let relevant = metadata.rateSamples.filter { $0.time >= cutoff }
        var windowRate = 0.0
        var windowSpan = 0.0
        if relevant.count >= 2, let first = relevant.first, let last = relevant.last {
            windowSpan = last.time - first.time
            if windowSpan > 0 {
                windowRate = Double(max(0, last.bytes - first.bytes)) / windowSpan
            }
        }

        var result: Double
        if windowRate > 0, windowSpan >= 0.50 {
            result = windowRate
        } else if windowRate > 0, average > 0 {
            result = windowRate * 0.85 + average * 0.15
        } else {
            result = windowRate > 0 ? windowRate : average
        }

        guard result > 0 else { return 0 }
        let staleFor = max(0, now - metadata.lastProgressAt)
        if staleFor > 0.50 {
            result *= max(0.20, 0.50 / staleFor)
        }
        return max(1, result)
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func relativeNoise(_ values: [Double], around center: Double) -> Double {
        guard center > 0, !values.isEmpty else { return 0 }
        let meanAbsoluteDeviation = values.reduce(0) { $0 + abs($1 - center) } / Double(values.count)
        return meanAbsoluteDeviation / center
    }

    private func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else {
            return 0
        }
        return number.int64Value
    }

    func handleITMSServicesURL(_ url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let manifestURLString = queryItems.first(where: { $0.name == "url" })?.value,
              let manifestURL = URL(string: manifestURLString) else {
            completion(.failure(NSError(domain: "ITMSError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid manifest URL"])))
            return
        }
        
        urlSession.dataTask(with: manifestURL) { [weak self] data, _, error in
            guard let self = self else { return }
            if let error = error { completion(.failure(error)); return }
            guard let data = data else { completion(.failure(NSError(domain: "ITMSError", code: 2, userInfo: [NSLocalizedDescriptionKey: "No data"]))); return }
            
            self.parseManifestPlist(data) { result in
                switch result {
                case .success(let url):
                    let filename = url.lastPathComponent.isEmpty ? "app.ipa" : url.lastPathComponent
                    self.startDownload(url: url, filename: filename)
                    completion(.success(filename))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    func checkFileTypeAndDownload(url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        if isIPAFile(url) {
            startDownload(url: url, filename: url.lastPathComponent)
            completion(.success(url.lastPathComponent))
        } else {
            completion(.failure(NSError(domain: "FileTypeError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid file type"])))
        }
    }
    
    private func parseManifestPlist(_ data: Data, completion: @escaping (Result<URL, Error>) -> Void) {
        do {
            if let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let items = plist["items"] as? [[String: Any]],
               let firstItem = items.first,
               let assets = firstItem["assets"] as? [[String: Any]] {
                
                for asset in assets {
                    if let kind = asset["kind"] as? String, kind == "software-package",
                       let urlString = asset["url"] as? String,
                       let url = URL(string: urlString) {
                        completion(.success(url))
                        return
                    }
                }
            }
            completion(.failure(NSError(domain: "ManifestParseError", code: 2, userInfo: [NSLocalizedDescriptionKey: "No IPA URL found"])))
        } catch {
            completion(.failure(error))
        }
    }
}

// MARK: - URLSession delegates

extension IPADownloadManager: URLSessionDownloadDelegate, URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard session === ipavaultSession else {
            completionHandler(.allow)
            return
        }

        guard let metadata = ipavaultTaskMetadata[dataTask.taskIdentifier],
              let job = ipavaultJobs[metadata.itemID],
              let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }

        guard http.statusCode == 206 else {
            let message = http.statusCode == 200
                ? "The server ignored the HTTP Range request required for adaptive downloading."
                : "Server returned HTTP \(http.statusCode)."
            metadata.terminalError = NSError(
                domain: "IPAVault",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
            completionHandler(.cancel)
            return
        }

        guard let value = http.value(forHTTPHeaderField: "Content-Range"),
              let contentRange = parseIPAVaultContentRange(value),
              contentRange.start == metadata.leaseStart,
              contentRange.end == metadata.requestEnd - 1,
              contentRange.total == job.totalBytes else {
            metadata.terminalError = NSError(
                domain: "IPAVault",
                code: 35,
                userInfo: [NSLocalizedDescriptionKey: "The server returned a mismatched Content-Range for an adaptive stream."]
            )
            completionHandler(.cancel)
            return
        }

        metadata.responseValidated = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard session === ipavaultSession,
              let metadata = ipavaultTaskMetadata[dataTask.taskIdentifier],
              let job = ipavaultJobs[metadata.itemID],
              metadata.responseValidated,
              job.fileDescriptor >= 0 else { return }

        let now = ProcessInfo.processInfo.systemUptime

        let remaining = max(0, metadata.effectiveEnd - metadata.currentPosition)
        let acceptedCount = min(data.count, Int(min(Int64(Int.max), remaining)))

        if !metadata.preempted, acceptedCount < data.count {
            metadata.terminalError = NSError(
                domain: "IPAVault",
                code: 36,
                userInfo: [NSLocalizedDescriptionKey: "The server sent more data than the requested byte range."]
            )
            dataTask.cancel()
            return
        }

        if acceptedCount > 0 {
            do {
                try writeIPAVaultData(data, count: acceptedCount, to: job.fileDescriptor, offset: metadata.currentPosition)
            } catch {
                metadata.terminalError = error
                dataTask.cancel()
                return
            }

            metadata.currentPosition += Int64(acceptedCount)
            recordIPAVaultUsefulBytes(Int64(acceptedCount), now: now)
            metadata.lastProgressAt = now
            let progressed = metadata.currentPosition - metadata.leaseStart
            if let last = metadata.rateSamples.last, now - last.time < 0.10 {
                metadata.rateSamples[metadata.rateSamples.count - 1] = IPAVaultWorkerRateSample(
                    time: now,
                    bytes: progressed
                )
            } else {
                metadata.rateSamples.append(IPAVaultWorkerRateSample(time: now, bytes: progressed))
            }
            let cutoff = now - ipavaultSpeedWindowSeconds
            while metadata.rateSamples.count > 2, metadata.rateSamples[1].time < cutoff {
                metadata.rateSamples.removeFirst()
            }

            commitIPAVaultBytes(metadata, job: job, through: metadata.currentPosition)
            updateIPAVaultProgress(for: job)
        }

        if metadata.preempted, metadata.currentPosition >= metadata.effectiveEnd {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard session !== ipavaultSession else { return }

        let fileManager = FileManager.default
        guard let downloadItemId = activeDownloads[downloadTask.taskIdentifier],
              let index = downloadItems.firstIndex(where: { $0.id.uuidString == downloadItemId }) else { return }

        let item = downloadItems[index]

        do {
            if fileManager.fileExists(atPath: item.localPath.path) {
                try fileManager.removeItem(at: item.localPath)
            }
            try fileManager.moveItem(at: location, to: item.localPath)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                var updatedItem = item
                updatedItem.url = item.localPath
                updatedItem.isFinished = true
                updatedItem.progress = 1.0
                if let fileSize = try? FileManager.default.attributesOfItem(atPath: item.localPath.path)[.size] as? Int64 {
                    updatedItem.totalBytes = fileSize
                    updatedItem.bytesDownloaded = fileSize
                }

                if index < self.downloadItems.count {
                    self.downloadItems[index] = updatedItem
                }
                self.activeDownloads.removeValue(forKey: downloadTask.taskIdentifier)
            }
        } catch {
            print("Error saving downloaded file: \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.downloadItems.remove(at: index)
                self?.activeDownloads.removeValue(forKey: downloadTask.taskIdentifier)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard session !== ipavaultSession else { return }

        guard let downloadItemId = activeDownloads[downloadTask.taskIdentifier],
              let index = downloadItems.firstIndex(where: { $0.id.uuidString == downloadItemId }) else { return }

        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0

        DispatchQueue.main.async { [weak self] in
            guard let self = self, index < self.downloadItems.count else { return }
            var item = self.downloadItems[index]
            item.progress = progress
            item.bytesDownloaded = totalBytesWritten
            item.totalBytes = totalBytesExpectedToWrite
            self.downloadItems[index] = item
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if session === ipavaultSession {
            if let metadata = ipavaultTaskMetadata[task.taskIdentifier], metadata.suppressCompletion {
                ipavaultTaskMetadata.removeValue(forKey: task.taskIdentifier)
                return
            }
            completeIPAVaultStream(taskIdentifier: task.taskIdentifier, error: error)
            return
        }

        if error != nil {
            guard let downloadItemId = activeDownloads[task.taskIdentifier],
                  let index = downloadItems.firstIndex(where: { $0.id.uuidString == downloadItemId }) else { return }

            DispatchQueue.main.async { [weak self] in
                self?.downloadItems.remove(at: index)
                self?.activeDownloads.removeValue(forKey: task.taskIdentifier)
            }
        }
        activeDownloads.removeValue(forKey: task.taskIdentifier)
    }
}

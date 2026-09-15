//
//  IPADownloadManager.swift
//  Ksign
//
//  Created by Nagata Asami on 5/24/25.
//

import SwiftUI
import WebKit

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

    private struct IPAVaultChunk {
        let index: Int
        let start: Int64
        let end: Int64
        var received: Int64

        var expectedLength: Int64 {
            max(0, end - start + 1)
        }
    }

    private struct IPAVaultTaskMetadata {
        let itemID: String
        let chunkIndex: Int
    }

    private final class IPAVaultJob {
        let itemID: String
        let url: URL
        let totalBytes: Int64
        let streamCount: Int
        let directory: URL
        var chunks: [IPAVaultChunk]
        var tasks: [Int: URLSessionDownloadTask] = [:]
        var assembling = false

        init(itemID: String, url: URL, totalBytes: Int64, streamCount: Int, directory: URL, chunks: [IPAVaultChunk]) {
            self.itemID = itemID
            self.url = url
            self.totalBytes = totalBytes
            self.streamCount = streamCount
            self.directory = directory
            self.chunks = chunks
        }
    }
    
    private var urlSession: URLSession!
    private var activeDownloads: [Int: String] = [:] // taskIdentifier -> downloadItem.id

    // IPA Vault has its own downloader so its concurrency/stream settings never
    // affect Ksign's ordinary downloader, imports, signing, or upload path.
    private var pendingIPAVaultDownloads: [PendingIPAVaultDownload] = []
    private var activeIPAVaultDownloadIDs: Set<String> = []
    private var ipavaultJobs: [String: IPAVaultJob] = [:]
    private var ipavaultTaskMetadata: [Int: IPAVaultTaskMetadata] = [:]
    private var maxConcurrentIPAVaultDownloads = 3
    private var ipavaultStreamsPerFile = 5

    // Live Activity batch accounting is intentionally separate from
    // `pendingIPAVaultDownloads` / `activeIPAVaultDownloadIDs`. Those collections
    // only describe work that has not finished yet, while the compact island needs
    // a stable denominator and a count of IPAs that made it all the way through
    // assembly and into Downloads.
    private var ipavaultActivityItemIDs: Set<String> = []
    private var completedIPAVaultActivityItemIDs: Set<String> = []

    private var ipavaultChunksRootURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KsignIPAVault", isDirectory: true)
            .appendingPathComponent("chunks", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private lazy var ipavaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 8 concurrent files * 10 streams per file is the UI maximum.
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
        downloadItems.removeAll()
        downloadItems.append(contentsOf: activeDownloads)
        
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
                    
                    let item = DownloadItem(
                        title: fileURL.lastPathComponent,
                        url: fileURL,
                        localPath: fileURL,
                        isFinished: true,
                        progress: 1.0,
                        totalBytes: fileSize,
                        bytesDownloaded: fileSize
                    )
                    downloadItems.append(item)
                }
            }
            
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

    /// Queues IPA Vault server -> Downloads transfers. `maxConcurrent` controls
    /// how many files run at once; `streamsPerFile` controls HTTP Range chunks
    /// within each active file. No other Ksign transfer path uses these values.
    func enqueueIPAVaultDownloads(
        _ files: [(url: URL, filename: String, size: Int64)],
        maxConcurrent: Int,
        streamsPerFile: Int
    ) {
        let work = {
            self.applyIPAVaultDownloadConfiguration(maxConcurrent: maxConcurrent, streamsPerFile: streamsPerFile)

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
                    bytesDownloaded: 0
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

            self.updateIPAVaultKeepAliveState()
            self.pumpIPAVaultDownloadQueue()
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    func configureIPAVaultDownloads(maxConcurrent: Int, streamsPerFile: Int) {
        let work = {
            self.applyIPAVaultDownloadConfiguration(maxConcurrent: maxConcurrent, streamsPerFile: streamsPerFile)
            self.pumpIPAVaultDownloadQueue()
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func applyIPAVaultDownloadConfiguration(maxConcurrent: Int, streamsPerFile: Int) {
        maxConcurrentIPAVaultDownloads = min(8, max(1, maxConcurrent))
        ipavaultStreamsPerFile = min(10, max(1, streamsPerFile))
    }

    // IPA Vault uses a foreground URLSession and performs its own chunk assembly,
    // so the keep-alive must already be running before the app backgrounds.
    // Starting silent audio only when assembly begins is too late: iOS may have
    // suspended us by then and a backgrounded app cannot reliably start a new
    // playback session. Hold one identity claim for the entire IPA Vault queue —
    // from the first queued transfer through the last assembly/move.
    private func updateIPAVaultKeepAliveState() {
        dispatchPrecondition(condition: .onQueue(.main))

        let hasWork = !pendingIPAVaultDownloads.isEmpty || !activeIPAVaultDownloadIDs.isEmpty

        if hasWork {
            if #available(iOS 16.2, *) {
                // Seed the report before claiming audio. `claim` immediately mirrors
                // its owners into ActivityKit, so doing this first guarantees the
                // activity is born with a compact n/n label instead of briefly
                // falling back to the long owner name ("IPA Vault downloads").
                let total = ipavaultActivityItemIDs.count
                let completed = completedIPAVaultActivityItemIDs
                    .intersection(ipavaultActivityItemIDs)
                    .count

                KeepAliveActivityController.shared.report(
                    .ipaVaultDownloads,
                    completed: completed,
                    total: total > 0 ? total : nil
                )

                let isFinishing = !activeIPAVaultDownloadIDs.isEmpty &&
                    activeIPAVaultDownloadIDs.allSatisfy { ipavaultJobs[$0]?.assembling == true }
                KeepAliveActivityController.shared.report(
                    .ipaVaultDownloads,
                    detail: isFinishing ? "Finishing IPA Vault downloads" : "Downloading from IPA Vault"
                )
            }

            BackgroundAudioManager.shared.claim(.ipaVaultDownloads)
        } else {
            if #available(iOS 16.2, *) {
                KeepAliveActivityController.shared.clearReport(.ipaVaultDownloads)
            }
            BackgroundAudioManager.shared.release(.ipaVaultDownloads)

            // The report has been withdrawn, so the next independently queued IPA
            // Vault batch must start at 0/n rather than inheriting the prior batch.
            ipavaultActivityItemIDs.removeAll()
            completedIPAVaultActivityItemIDs.removeAll()
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
            pumpIPAVaultDownloadQueue()
            updateIPAVaultKeepAliveState()
            return true
        }

        guard let job = ipavaultJobs.removeValue(forKey: itemID) else { return false }

        for (taskID, task) in job.tasks {
            ipavaultTaskMetadata.removeValue(forKey: taskID)
            task.cancel()
        }
        activeIPAVaultDownloadIDs.remove(itemID)
        downloadItems.removeAll { $0.id.uuidString == itemID }
        ipavaultActivityItemIDs.remove(itemID)
        completedIPAVaultActivityItemIDs.remove(itemID)
        try? FileManager.default.removeItem(at: job.directory)
        pumpIPAVaultDownloadQueue()
        updateIPAVaultKeepAliveState()
        return true
    }

    private func pumpIPAVaultDownloadQueue() {
        dispatchPrecondition(condition: .onQueue(.main))

        while activeIPAVaultDownloadIDs.count < maxConcurrentIPAVaultDownloads,
              !pendingIPAVaultDownloads.isEmpty {
            let pending = pendingIPAVaultDownloads.removeFirst()
            guard downloadItems.contains(where: { $0.id.uuidString == pending.itemID && !$0.isFinished }) else {
                continue
            }
            startIPAVaultDownload(pending)
        }
    }

    private func startIPAVaultDownload(_ pending: PendingIPAVaultDownload) {
        let maxStreamsBySize: Int
        if pending.totalBytes > Int64(Int.max) {
            maxStreamsBySize = Int.max
        } else {
            maxStreamsBySize = max(1, Int(pending.totalBytes))
        }
        let streamCount = min(ipavaultStreamsPerFile, maxStreamsBySize)
        let chunks = makeIPAVaultChunks(totalBytes: pending.totalBytes, count: streamCount)
        let directory = ipavaultChunksRootURL.appendingPathComponent(pending.itemID, isDirectory: true)

        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            failIPAVaultDownload(itemID: pending.itemID, error: error)
            return
        }

        let job = IPAVaultJob(
            itemID: pending.itemID,
            url: pending.url,
            totalBytes: pending.totalBytes,
            streamCount: streamCount,
            directory: directory,
            chunks: chunks
        )
        ipavaultJobs[pending.itemID] = job
        activeIPAVaultDownloadIDs.insert(pending.itemID)
        updateIPAVaultKeepAliveState()

        for chunk in chunks {
            var request = URLRequest(url: pending.url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 60
            request.setValue("bytes=\(chunk.start)-\(chunk.end)", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

            let task = ipavaultSession.downloadTask(with: request)
            job.tasks[task.taskIdentifier] = task
            ipavaultTaskMetadata[task.taskIdentifier] = IPAVaultTaskMetadata(
                itemID: pending.itemID,
                chunkIndex: chunk.index
            )
            task.countOfBytesClientExpectsToReceive = chunk.expectedLength
            task.resume()
        }
    }

    private func makeIPAVaultChunks(totalBytes: Int64, count: Int) -> [IPAVaultChunk] {
        let safeCount = max(1, min(count, Int(min(totalBytes, Int64(Int.max)))))
        let base = totalBytes / Int64(safeCount)
        let remainder = totalBytes % Int64(safeCount)
        var cursor: Int64 = 0
        var chunks: [IPAVaultChunk] = []

        for index in 0..<safeCount {
            let length = base + (Int64(index) < remainder ? 1 : 0)
            let start = cursor
            let end = cursor + length - 1
            chunks.append(IPAVaultChunk(index: index, start: start, end: end, received: 0))
            cursor = end + 1
        }
        return chunks
    }

    private func updateIPAVaultProgress(itemID: String, totalBytes: Int64, bytesDownloaded: Int64) {
        guard let index = downloadItems.firstIndex(where: { $0.id.uuidString == itemID }) else { return }
        let downloaded = min(totalBytes, max(0, bytesDownloaded))
        var item = downloadItems[index]
        item.totalBytes = totalBytes
        item.bytesDownloaded = downloaded
        item.progress = totalBytes > 0 ? Double(downloaded) / Double(totalBytes) : 0
        downloadItems[index] = item
    }

    private func handleIPAVaultChunkProgress(
        taskIdentifier: Int,
        totalBytesWritten: Int64
    ) {
        guard let metadata = ipavaultTaskMetadata[taskIdentifier],
              let job = ipavaultJobs[metadata.itemID],
              job.chunks.indices.contains(metadata.chunkIndex) else { return }

        let expected = job.chunks[metadata.chunkIndex].expectedLength
        job.chunks[metadata.chunkIndex].received = min(expected, max(0, totalBytesWritten))
        let total = job.chunks.reduce(Int64(0)) { $0 + min($1.received, $1.expectedLength) }
        updateIPAVaultProgress(itemID: metadata.itemID, totalBytes: job.totalBytes, bytesDownloaded: total)
    }

    private func handleIPAVaultChunkFinished(
        downloadTask: URLSessionDownloadTask,
        location: URL
    ) {
        let taskID = downloadTask.taskIdentifier
        guard let metadata = ipavaultTaskMetadata[taskID],
              let job = ipavaultJobs[metadata.itemID],
              job.chunks.indices.contains(metadata.chunkIndex) else { return }

        guard let response = downloadTask.response as? HTTPURLResponse else {
            failIPAVaultDownload(
                itemID: metadata.itemID,
                error: NSError(domain: "IPAVault", code: 1, userInfo: [NSLocalizedDescriptionKey: "The server returned an invalid response."])
            )
            return
        }

        guard response.statusCode == 206 else {
            let message = response.statusCode == 200
                ? "The server ignored the HTTP Range request required for multi-stream downloading."
                : "Server returned HTTP \(response.statusCode)."
            failIPAVaultDownload(
                itemID: metadata.itemID,
                error: NSError(domain: "IPAVault", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            )
            return
        }

        let chunk = job.chunks[metadata.chunkIndex]
        let receivedSize = fileSize(at: location)
        guard receivedSize == chunk.expectedLength else {
            failIPAVaultDownload(
                itemID: metadata.itemID,
                error: NSError(
                    domain: "IPAVault",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "A download stream ended early (\(receivedSize) of \(chunk.expectedLength) bytes)."]
                )
            )
            return
        }

        let chunkURL = job.directory.appendingPathComponent(String(format: "chunk-%03d.part", chunk.index))

        do {
            if FileManager.default.fileExists(atPath: chunkURL.path) {
                try FileManager.default.removeItem(at: chunkURL)
            }
            try FileManager.default.moveItem(at: location, to: chunkURL)
        } catch {
            failIPAVaultDownload(itemID: metadata.itemID, error: error)
            return
        }

        job.chunks[metadata.chunkIndex].received = chunk.expectedLength
        job.tasks.removeValue(forKey: taskID)
        ipavaultTaskMetadata.removeValue(forKey: taskID)

        let total = job.chunks.reduce(Int64(0)) { $0 + min($1.received, $1.expectedLength) }
        updateIPAVaultProgress(itemID: metadata.itemID, totalBytes: job.totalBytes, bytesDownloaded: total)

        if !job.assembling && job.chunks.allSatisfy({ $0.received == $0.expectedLength }) {
            beginIPAVaultAssembly(job)
        }
    }

    private func beginIPAVaultAssembly(_ job: IPAVaultJob) {
        guard !job.assembling else { return }
        job.assembling = true
        updateIPAVaultKeepAliveState()

        let itemID = job.itemID
        let directory = job.directory
        let chunks = job.chunks
        let totalBytes = job.totalBytes

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let result: Result<URL, Error>
            do {
                let assembledURL = try self.assembleIPAVaultChunks(
                    directory: directory,
                    chunks: chunks,
                    expectedTotalBytes: totalBytes
                )
                result = .success(assembledURL)
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                self?.finishIPAVaultAssembly(itemID: itemID, result: result)
            }
        }
    }

    private func assembleIPAVaultChunks(
        directory: URL,
        chunks: [IPAVaultChunk],
        expectedTotalBytes: Int64
    ) throws -> URL {
        let outputURL = directory.appendingPathComponent("assembled.partial")
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        for chunk in chunks.sorted(by: { $0.index < $1.index }) {
            let chunkURL = directory.appendingPathComponent(String(format: "chunk-%03d.part", chunk.index))
            let input = try FileHandle(forReadingFrom: chunkURL)

            while true {
                let data = try input.read(upToCount: 1024 * 1024) ?? Data()
                if data.isEmpty { break }
                try output.write(contentsOf: data)
            }
            try input.close()
        }

        try output.synchronize()
        let finalSize = fileSize(at: outputURL)
        guard finalSize == expectedTotalBytes else {
            throw NSError(
                domain: "IPAVault",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "The assembled IPA is incomplete (\(finalSize) of \(expectedTotalBytes) bytes)."]
            )
        }
        return outputURL
    }

    private func finishIPAVaultAssembly(itemID: String, result: Result<URL, Error>) {
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
                    error: NSError(domain: "IPAVault", code: 4, userInfo: [NSLocalizedDescriptionKey: "The download item disappeared before assembly completed."])
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
                item.isFinished = true
                item.progress = 1
                item.totalBytes = job.totalBytes
                item.bytesDownloaded = job.totalBytes
                downloadItems[index] = item

                completedIPAVaultActivityItemIDs.insert(itemID)
                ipavaultJobs.removeValue(forKey: itemID)
                activeIPAVaultDownloadIDs.remove(itemID)
                try? FileManager.default.removeItem(at: job.directory)
                pumpIPAVaultDownloadQueue()
                updateIPAVaultKeepAliveState()
            } catch {
                failIPAVaultDownload(itemID: itemID, error: error)
            }
        }
    }

    private func failIPAVaultDownload(itemID: String, error: Error) {
        dispatchPrecondition(condition: .onQueue(.main))
        print("IPA Vault download failed: \(error.localizedDescription)")

        if let job = ipavaultJobs.removeValue(forKey: itemID) {
            for (taskID, task) in job.tasks {
                ipavaultTaskMetadata.removeValue(forKey: taskID)
                task.cancel()
            }
            try? FileManager.default.removeItem(at: job.directory)
        }

        activeIPAVaultDownloadIDs.remove(itemID)
        downloadItems.removeAll { $0.id.uuidString == itemID }
        ipavaultActivityItemIDs.remove(itemID)
        completedIPAVaultActivityItemIDs.remove(itemID)
        pumpIPAVaultDownloadQueue()
        updateIPAVaultKeepAliveState()
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

// MARK: - URLSessionDownloadDelegate

extension IPADownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if session === ipavaultSession {
            handleIPAVaultChunkFinished(downloadTask: downloadTask, location: location)
            return
        }

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
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if session === ipavaultSession {
            handleIPAVaultChunkProgress(
                taskIdentifier: downloadTask.taskIdentifier,
                totalBytesWritten: totalBytesWritten
            )
            return
        }

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
            guard let metadata = ipavaultTaskMetadata[task.taskIdentifier] else { return }
            if let error {
                failIPAVaultDownload(itemID: metadata.itemID, error: error)
            }
            return
        }

        if let error = error {
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

// Download presentation and ordinary URLSession downloads.
import SwiftUI
import WebKit
import UIKit

// Menu availability changes independently of progress and tuning statistics.
final class IPAVaultDownloadControls: ObservableObject {
    @Published private(set) var state = IPAVaultTransfer.Controls()

    fileprivate func apply(_ next: IPAVaultTransfer.Controls) {
        if state != next { state = next }
    }
}

// UI rows are main-queue owned; URLSession bookkeeping is protected by taskLock.
final class IPADownloadManager: NSObject, ObservableObject, @unchecked Sendable {
    @Published var downloadItems: [DownloadItem] = []
    var activeItems: [DownloadItem] { downloadItems.filter { !$0.isFinished } }
    var finishedItems: [DownloadItem] { downloadItems.filter { $0.isFinished } }
    let vaultControls = IPAVaultDownloadControls()
    @Published private(set) var ipavaultAdaptiveConcurrentCount = 0
    @Published private(set) var ipavaultAdaptiveStreamsPerFile = 2
    @Published private(set) var ipavaultAdaptiveStatus = "Idle"
    @Published private(set) var ipavaultAdaptiveStreamCount = 0
    @Published private(set) var ipavaultAdaptiveSpeedBPS: Double = 0

    private var vault: IPAVaultTransfer!
    private var vaultDelivery: LatestValueDelivery<IPAVaultTransfer.Presentation>!
    private var lastVaultItems: [UUID: DownloadItem] = [:]
    private var observers: [NSObjectProtocol] = []
    private let filesQueue = DispatchQueue(label: "Asign.download-files", qos: .utility)
    private var listingGeneration = UUID()
    private var urlSession: URLSession!
    private let taskLock = NSLock()
    private var activeDownloads: [Int: DownloadItem] = [:]
    private var ordinaryProgress: [Int: ForegroundValueDelivery<DownloadItem>] = [:]

    override init() {
        super.init()
        vaultDelivery = LatestValueDelivery(interval: 0) { [weak self] in self?.applyVault($0) }
        let delivery = vaultDelivery!
        vault = IPAVaultTransfer { delivery.submit($0) }
        setupURLSession()
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                self?.vault.setActive(event.name == UIApplication.didBecomeActiveNotification)
            })
        }
        vault.setActive(UIApplication.shared.applicationState == .active)
        loadDownloadedIPAs()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func applyVault(_ snapshot: IPAVaultTransfer.Presentation) {
        vaultControls.apply(snapshot.controls)
        let next = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        let removed = Set(lastVaultItems.keys).subtracting(next.keys)
        var items = downloadItems.filter { !removed.contains($0.id) }
        for item in snapshot.items.reversed() where lastVaultItems[item.id] != item {
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
            else if lastVaultItems[item.id] == nil { items.insert(item, at: 0) }
        }
        lastVaultItems = next
        if items != downloadItems { downloadItems = items }
        let adaptive = snapshot.adaptive
        if ipavaultAdaptiveConcurrentCount != adaptive.concurrentCount { ipavaultAdaptiveConcurrentCount = adaptive.concurrentCount }
        if ipavaultAdaptiveStreamsPerFile != adaptive.streamsPerFile { ipavaultAdaptiveStreamsPerFile = adaptive.streamsPerFile }
        if ipavaultAdaptiveStatus != adaptive.status { ipavaultAdaptiveStatus = adaptive.status }
        if ipavaultAdaptiveStreamCount != adaptive.streamCount { ipavaultAdaptiveStreamCount = adaptive.streamCount }
        if ipavaultAdaptiveSpeedBPS != adaptive.speedBPS { ipavaultAdaptiveSpeedBPS = adaptive.speedBPS }
    }

    func enqueueIPAVaultDownloads(_ files: [(url: URL, filename: String, size: Int64)]) {
        if files.contains(where: { $0.size > 0 }) {
            BackgroundTaskManager.shared.claim(.ipaVaultDownloads)
        }
        vault.enqueueIPAVaultDownloads(files)
    }
    func pauseIPAVaultDownload(_ item: DownloadItem) { vault.pauseIPAVaultDownload(item) }
    func resumeIPAVaultDownload(_ item: DownloadItem) { vault.resumeIPAVaultDownload(item) }
    func pauseAllIPAVaultDownloads() { vault.pauseAllIPAVaultDownloads() }
    func resumeAllIPAVaultDownloads() { vault.resumeAllIPAVaultDownloads() }
    func pauseAllQueuedIPAVaultDownloads() { vault.pauseAllQueuedIPAVaultDownloads() }
    func cancelAllQueuedIPAVaultDownloads() { vault.cancelAllQueuedIPAVaultDownloads() }

    private func setupURLSession() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func isIPAFile(_ url: URL) -> Bool { url.pathExtension.lowercased() == "ipa" }

    func loadDownloadedIPAs() {
        let generation = UUID()
        listingGeneration = generation
        let observed = downloadItems.filter(\.isFinished)
        filesQueue.async { [weak self] in
            let directory = URL.documentsDirectory.appendingPathComponent("Downloads")
            do {
                try FileManager.default.createDirectoryIfNeeded(at: directory)
                let urls = try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.fileSizeKey])
                let files = try urls.filter { $0.pathExtension.lowercased() == "ipa" }.map {
                    (url: $0, size: Int64(try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.listingGeneration == generation else { return }
                    // Merge into current UI state; downloads can finish during enumeration.
                    let paths = Set(files.map(\.url))
                    let absent = Set(observed.filter { !paths.contains($0.localPath) }.map(\.id))
                    var items = self.downloadItems.filter { !absent.contains($0.id) }
                    for id in absent { self.vault.forgetFinishedDownload(id) }
                    for file in files {
                        if let index = items.firstIndex(where: { $0.localPath == file.url }) {
                            if items[index].isFinished {
                                items[index].totalBytes = file.size
                                items[index].bytesDownloaded = file.size
                            }
                        } else {
                            items.append(DownloadItem(title: file.url.lastPathComponent, url: file.url,
                                localPath: file.url, isFinished: true, progress: 1,
                                totalBytes: file.size, bytesDownloaded: file.size))
                        }
                    }
                    if items != self.downloadItems { self.downloadItems = items }
                }
            } catch { print("Failed to load downloaded IPAs: \(error)") }
        }
    }

    func startDownload(url: URL, filename: String) {
        filesQueue.async { [weak self] in
            guard let self else { return }
            let directory = URL.documentsDirectory.appendingPathComponent("Downloads")
            do { try FileManager.default.createDirectoryIfNeeded(at: directory) }
            catch { print("Cannot prepare download: \(error)"); return }
            let item = DownloadItem(title: filename, url: url, localPath: directory.appendingPathComponent(filename),
                                    isFinished: false, progress: 0, totalBytes: 0, bytesDownloaded: 0)
            let task = self.urlSession.downloadTask(with: url)
            let delivery = ForegroundValueDelivery<DownloadItem> { [weak self] update in
                guard let self, let index = self.downloadItems.firstIndex(where: { $0.id == update.id }),
                      !self.downloadItems[index].isFinished else { return }
                if self.downloadItems[index] != update { self.downloadItems[index] = update }
            }
            self.taskLock.lock()
            self.activeDownloads[task.taskIdentifier] = item
            self.ordinaryProgress[task.taskIdentifier] = delivery
            self.taskLock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.downloadItems.insert(item, at: 0)
                task.resume()
            }
        }
    }

    func deleteFinishedDownload(_ item: DownloadItem) {
        listingGeneration = UUID()
        filesQueue.async { [weak self] in
            do {
                try FileManager.default.removeItem(at: item.localPath)
                DispatchQueue.main.async { [weak self] in
                    self?.listingGeneration = UUID()
                    self?.downloadItems.removeAll { $0.id == item.id }
                    self?.vault.forgetFinishedDownload(item.id)
                }
            } catch {
                DispatchQueue.main.async {
                    UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
                }
            }
        }
    }

    func cancelDownload(_ item: DownloadItem) {
        if item.isIPAVaultDownload { vault.cancelDownload(item); return }
        urlSession.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.taskLock.lock()
            let ids = Set(self.activeDownloads.filter { $0.value.id == item.id }.map(\.key))
            self.taskLock.unlock()
            tasks.filter { ids.contains($0.taskIdentifier) }.forEach { $0.cancel() }
        }
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

extension IPADownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        taskLock.lock()
        var item = activeDownloads[downloadTask.taskIdentifier]
        let delivery = ordinaryProgress[downloadTask.taskIdentifier]
        if item != nil {
            item!.progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
            item!.bytesDownloaded = totalBytesWritten
            item!.totalBytes = totalBytesExpectedToWrite
            activeDownloads[downloadTask.taskIdentifier] = item
        }
        taskLock.unlock()
        if let item { delivery?.submit(item) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        taskLock.lock()
        let item = activeDownloads.removeValue(forKey: downloadTask.taskIdentifier)
        ordinaryProgress.removeValue(forKey: downloadTask.taskIdentifier)?.cancel()
        taskLock.unlock()
        guard var item else { return }
        // URLSession owns the temporary file only until this delegate returns.
        // Its delegate queue is a background serial queue, so move it here.
        do {
            if FileManager.default.fileExists(atPath: item.localPath.path) { try FileManager.default.removeItem(at: item.localPath) }
            try FileManager.default.moveItem(at: location, to: item.localPath)
            item.url = item.localPath
            item.isFinished = true
            item.progress = 1
            item.totalBytes = Int64(try item.localPath.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            item.bytesDownloaded = item.totalBytes
            let completed = item
            DispatchQueue.main.async { [weak self] in
                guard let self, let index = self.downloadItems.firstIndex(where: { $0.id == completed.id }) else { return }
                self.downloadItems[index] = completed
            }
        } catch {
            print("Error saving downloaded file: \(error)")
            removeOrdinaryItem(item.id)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        taskLock.lock()
        let item = activeDownloads.removeValue(forKey: task.taskIdentifier)
        ordinaryProgress.removeValue(forKey: task.taskIdentifier)?.cancel()
        taskLock.unlock()
        if error != nil, let item { removeOrdinaryItem(item.id) }
    }

    private func removeOrdinaryItem(_ id: UUID) {
        DispatchQueue.main.async { [weak self] in self?.downloadItems.removeAll { $0.id == id } }
    }
}

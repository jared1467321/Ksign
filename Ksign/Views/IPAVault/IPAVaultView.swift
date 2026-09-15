import SwiftUI

private enum IPAVaultMode: String, CaseIterable, Identifiable {
    case download
    case upload

    var id: String { rawValue }

    var title: String {
        switch self {
        case .download: return "Server → iPhone"
        case .upload: return "iPhone → Server"
        }
    }
}

private struct IPAVaultNginxEntry: Decodable {
    let name: String
    let type: String
    let size: Int64?
}

private struct IPAVaultRemoteFile: Identifiable, Hashable {
    let name: String
    let size: Int64
    let url: URL

    var id: String { url.absoluteString }
}

private struct IPAVaultLocalFile: Identifiable, Hashable {
    let name: String
    let size: Int64
    let url: URL

    var id: String { url.path }
}

private enum IPAVaultUploadState: Equatable {
    case queued
    case uploading
    case completed
    case failed(String)
    case cancelled
}

private struct IPAVaultUploadJob: Identifiable {
    let id: UUID
    let file: IPAVaultLocalFile
    let remoteURL: URL
    var state: IPAVaultUploadState
    var bytesSent: Int64
    var totalBytes: Int64
    var bytesPerSecond: Double

    var progress: Double {
        guard totalBytes > 0 else { return state == .completed ? 1 : 0 }
        return min(1, max(0, Double(bytesSent) / Double(totalBytes)))
    }
}

private final class IPAVaultUploadManager: NSObject, ObservableObject, URLSessionTaskDelegate {
    static let shared = IPAVaultUploadManager()

    @Published private(set) var jobs: [IPAVaultUploadJob] = []

    private var taskToJobID: [Int: UUID] = [:]
    private var samples: [UUID: (time: Date, bytes: Int64, speed: Double)] = [:]
    private var queuedJobIDs: [UUID] = []
    private var activeJobIDs: Set<UUID> = []
    private var maxConcurrentFiles = 3

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue.main)
    }()

    private override init() {
        super.init()
    }

    func setMaxConcurrentFiles(_ value: Int) {
        maxConcurrentFiles = min(8, max(1, value))
        pumpQueue()
    }

    func enqueue(_ files: [IPAVaultLocalFile], baseURL: URL, maxConcurrent: Int) {
        setMaxConcurrentFiles(maxConcurrent)

        for file in files {
            let remoteURL = baseURL.appendingPathComponent(file.name, isDirectory: false)
            let id = UUID()
            let job = IPAVaultUploadJob(
                id: id,
                file: file,
                remoteURL: remoteURL,
                state: .queued,
                bytesSent: 0,
                totalBytes: file.size,
                bytesPerSecond: 0
            )
            jobs.insert(job, at: 0)
            queuedJobIDs.append(id)
        }

        pumpQueue()
    }

    func cancel(_ id: UUID) {
        if let queueIndex = queuedJobIDs.firstIndex(of: id) {
            queuedJobIDs.remove(at: queueIndex)
            if let jobIndex = jobs.firstIndex(where: { $0.id == id }) {
                jobs[jobIndex].state = .cancelled
                jobs[jobIndex].bytesPerSecond = 0
            }
            pumpQueue()
            return
        }

        guard let taskID = taskToJobID.first(where: { $0.value == id })?.key else { return }
        session.getAllTasks { tasks in
            tasks.first(where: { $0.taskIdentifier == taskID })?.cancel()
        }
    }

    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let old = jobs[index]
        guard case .failed = old.state else { return }
        jobs.remove(at: index)
        enqueue(
            [old.file],
            baseURL: old.remoteURL.deletingLastPathComponent(),
            maxConcurrent: maxConcurrentFiles
        )
    }

    func clearFinished() {
        jobs.removeAll {
            switch $0.state {
            case .completed, .cancelled: return true
            default: return false
            }
        }
    }

    private func pumpQueue() {
        while activeJobIDs.count < maxConcurrentFiles, !queuedJobIDs.isEmpty {
            let id = queuedJobIDs.removeFirst()
            guard let index = jobs.firstIndex(where: { $0.id == id }),
                  case .queued = jobs[index].state else { continue }
            startUpload(at: index)
        }
    }

    private func startUpload(at index: Int) {
        let job = jobs[index]

        var request = URLRequest(url: job.remoteURL)
        request.httpMethod = "PUT"
        request.timeoutInterval = 60 * 60
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(job.file.size), forHTTPHeaderField: "Content-Length")

        let task = session.uploadTask(with: request, fromFile: job.file.url)
        jobs[index].state = .uploading
        taskToJobID[task.taskIdentifier] = job.id
        activeJobIDs.insert(job.id)
        samples[job.id] = (Date(), 0, 0)
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let id = taskToJobID[task.taskIdentifier],
              let index = jobs.firstIndex(where: { $0.id == id }) else { return }

        let now = Date()
        let previous = samples[id] ?? (now, 0, 0)
        let elapsed = now.timeIntervalSince(previous.time)
        var speed = previous.speed

        if elapsed >= 0.4 {
            let instant = Double(max(0, totalBytesSent - previous.bytes)) / elapsed
            speed = previous.speed > 0 ? (previous.speed * 0.7 + instant * 0.3) : instant
            samples[id] = (now, totalBytesSent, speed)
        }

        jobs[index].bytesSent = totalBytesSent
        if totalBytesExpectedToSend > 0 {
            jobs[index].totalBytes = totalBytesExpectedToSend
        }
        jobs[index].bytesPerSecond = speed
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = taskToJobID.removeValue(forKey: task.taskIdentifier),
              let index = jobs.firstIndex(where: { $0.id == id }) else { return }

        activeJobIDs.remove(id)
        defer {
            samples.removeValue(forKey: id)
            pumpQueue()
        }

        if let urlError = error as? URLError, urlError.code == .cancelled {
            jobs[index].state = .cancelled
            jobs[index].bytesPerSecond = 0
            return
        }

        if let error {
            jobs[index].state = .failed(error.localizedDescription)
            jobs[index].bytesPerSecond = 0
            return
        }

        guard let response = task.response as? HTTPURLResponse else {
            jobs[index].state = .failed("The server returned an invalid response.")
            jobs[index].bytesPerSecond = 0
            return
        }

        guard (200..<300).contains(response.statusCode) else {
            jobs[index].state = .failed("Server returned HTTP \(response.statusCode).")
            jobs[index].bytesPerSecond = 0
            return
        }

        jobs[index].bytesSent = jobs[index].totalBytes
        jobs[index].bytesPerSecond = 0
        jobs[index].state = .completed
    }
}

struct IPAVaultView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var downloadManager: IPADownloadManager
    @ObservedObject private var uploadManager = IPAVaultUploadManager.shared

    @AppStorage("Ksign.IPAVault.serverURL") private var serverURL = "http://100.89.243.68:8765/"
    @AppStorage("Ksign.IPAVault.mode") private var modeRaw = IPAVaultMode.download.rawValue
    @AppStorage("Ksign.IPAVault.concurrentFiles") private var concurrentFiles = 3

    @State private var remoteFiles: [IPAVaultRemoteFile] = []
    @State private var localFiles: [IPAVaultLocalFile] = []
    @State private var selectedRemote: Set<String> = []
    @State private var selectedLocal: Set<String> = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var showingSettings = false
    @State private var pendingDelete: IPAVaultRemoteFile?
    @State private var pendingBatchDelete: [IPAVaultRemoteFile] = []
    @State private var deletingIDs: Set<String> = []

    private var mode: IPAVaultMode {
        IPAVaultMode(rawValue: modeRaw) ?? .download
    }

    private var normalizedServerURL: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed.hasSuffix("/") ? trimmed : trimmed + "/")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Transfer Direction", selection: $modeRaw) {
                    ForEach(IPAVaultMode.allCases) { value in
                        Text(value.title).tag(value.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                Divider()

                if mode == .download {
                    remoteContent
                } else {
                    localContent
                }
            }
            .navigationTitle("IPA Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }

                    Button {
                        Task { await refreshCurrentMode() }
                    } label: {
                        if loading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(loading)
                }
            }
            .safeAreaInset(edge: .bottom) {
                actionBar
            }
            .task {
                let clamped = min(8, max(1, concurrentFiles))
                if concurrentFiles != clamped {
                    concurrentFiles = clamped
                }
                downloadManager.setIPAVaultConcurrentDownloads(clamped)
                uploadManager.setMaxConcurrentFiles(clamped)
                await refreshCurrentMode()
            }
            .onChange(of: modeRaw) { _ in
                Task { await refreshCurrentMode() }
            }
            .onChange(of: concurrentFiles) { value in
                let clamped = min(8, max(1, value))
                if value != clamped {
                    concurrentFiles = clamped
                    return
                }
                downloadManager.setIPAVaultConcurrentDownloads(clamped)
                uploadManager.setMaxConcurrentFiles(clamped)
            }
            .sheet(isPresented: $showingSettings) {
                IPAVaultSettingsView(serverURL: $serverURL, concurrentFiles: $concurrentFiles)
            }
            .alert("IPA Vault", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
            .confirmationDialog(
                "Delete from Server?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { file in
                Button("Delete \(file.name)", role: .destructive) {
                    Task { await deleteFromServer(file) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { file in
                Text("This permanently removes \(file.name) from the VPS. A copy already downloaded to Ksign is not affected.")
            }
            .confirmationDialog(
                pendingBatchDelete.count == 1 ? "Delete 1 File from Server?" : "Delete \(pendingBatchDelete.count) Files from Server?",
                isPresented: Binding(
                    get: { !pendingBatchDelete.isEmpty },
                    set: { if !$0 { pendingBatchDelete.removeAll() } }
                )
            ) {
                Button(
                    pendingBatchDelete.count == 1 ? "Delete 1 File" : "Delete \(pendingBatchDelete.count) Files",
                    role: .destructive
                ) {
                    let filesToDelete = pendingBatchDelete
                    pendingBatchDelete.removeAll()
                    Task { await deleteSelectedFromServer(filesToDelete) }
                }
                Button("Cancel", role: .cancel) {
                    pendingBatchDelete.removeAll()
                }
            } message: {
                Text("This permanently removes the selected files from the VPS. Copies already downloaded to Ksign are not affected.")
            }
        }
    }

    @ViewBuilder
    private var remoteContent: some View {
        if loading && remoteFiles.isEmpty {
            Spacer()
            ProgressView("Loading IPA Vault…")
            Spacer()
        } else if remoteFiles.isEmpty {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.wifi")
                    .font(.system(size: 38))
                    .foregroundStyle(.secondary)
                Text("No IPA files found")
                    .font(.headline)
                Text("Check the server address or add IPA files to the VPS folder.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            Spacer()
        } else {
            List {
                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach(remoteFiles) { file in
                        Button {
                            toggleRemote(file)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedRemote.contains(file.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedRemote.contains(file.id) ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(file.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                if hasActiveDownload(for: file) {
                                    errorMessage = "Cancel or finish this file’s active download before deleting it from the server."
                                } else {
                                    pendingDelete = file
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(deletingIDs.contains(file.id))
                        }
                    }
                } header: {
                    HStack {
                        Text("Server")
                        Spacer()
                        Button(selectedRemote.count == remoteFiles.count ? "Clear" : "Select All") {
                            if selectedRemote.count == remoteFiles.count {
                                selectedRemote.removeAll()
                            } else {
                                selectedRemote = Set(remoteFiles.map(\.id))
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await refreshRemoteFiles() }
        }
    }

    @ViewBuilder
    private var localContent: some View {
        List {
            if !uploadManager.jobs.isEmpty {
                Section("Uploads") {
                    ForEach(uploadManager.jobs) { job in
                        IPAVaultUploadRow(job: job, manager: uploadManager)
                    }

                    if uploadManager.jobs.contains(where: {
                        switch $0.state {
                        case .completed, .cancelled: return true
                        default: return false
                        }
                    }) {
                        Button("Clear Finished") {
                            uploadManager.clearFinished()
                        }
                    }
                }
            }

            Section {
                if localFiles.isEmpty {
                    Text("No files are in Ksign's Downloads folder.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(localFiles) { file in
                        Button {
                            toggleLocal(file)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedLocal.contains(file.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedLocal.contains(file.id) ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(file.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                HStack {
                    Text("Ksign Downloads")
                    Spacer()
                    if !localFiles.isEmpty {
                        Button(selectedLocal.count == localFiles.count ? "Clear" : "Select All") {
                            if selectedLocal.count == localFiles.count {
                                selectedLocal.removeAll()
                            } else {
                                selectedLocal = Set(localFiles.map(\.id))
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await refreshLocalFiles() }
    }

    @ViewBuilder
    private var actionBar: some View {
        if mode == .download && !selectedRemote.isEmpty {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 10) {
                    Button {
                        downloadSelected()
                    } label: {
                        Label(
                            selectedRemote.count == 1 ? "Download 1" : "Download \(selectedRemote.count)",
                            systemImage: "arrow.down.circle.fill"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        prepareBatchDelete()
                    } label: {
                        Label(
                            selectedRemote.count == 1 ? "Delete 1" : "Delete \(selectedRemote.count)",
                            systemImage: "trash.fill"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!deletingIDs.isDisjoint(with: selectedRemote))
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
            }
        } else if mode == .upload && !selectedLocal.isEmpty {
            VStack(spacing: 0) {
                Divider()
                Button {
                    uploadSelected()
                } label: {
                    Label(
                        selectedLocal.count == 1 ? "Send 1" : "Send \(selectedLocal.count)",
                        systemImage: "arrow.up.circle.fill"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
    }

    private func toggleRemote(_ file: IPAVaultRemoteFile) {
        if selectedRemote.contains(file.id) {
            selectedRemote.remove(file.id)
        } else {
            selectedRemote.insert(file.id)
        }
    }

    private func toggleLocal(_ file: IPAVaultLocalFile) {
        if selectedLocal.contains(file.id) {
            selectedLocal.remove(file.id)
        } else {
            selectedLocal.insert(file.id)
        }
    }

    private func downloadSelected() {
        let selected = remoteFiles.filter { selectedRemote.contains($0.id) }
        let downloads = selected.map { (url: $0.url, filename: $0.name) }
        downloadManager.enqueueIPAVaultDownloads(downloads, maxConcurrent: concurrentFiles)
        statusMessage = selected.count == 1
            ? "Added 1 IPA to Ksign Downloads."
            : "Added \(selected.count) IPAs to Ksign Downloads."
        selectedRemote.removeAll()
    }

    private func uploadSelected() {
        guard let baseURL = normalizedServerURL else {
            errorMessage = "Enter a valid server URL in IPA Vault settings."
            return
        }
        let selected = localFiles.filter { selectedLocal.contains($0.id) }
        uploadManager.enqueue(selected, baseURL: baseURL, maxConcurrent: concurrentFiles)
        selectedLocal.removeAll()
    }

    private func hasActiveDownload(for file: IPAVaultRemoteFile) -> Bool {
        downloadManager.downloadItems.contains { item in
            !item.isFinished && item.url == file.url
        }
    }

    private func prepareBatchDelete() {
        let selected = remoteFiles.filter { selectedRemote.contains($0.id) }
        guard !selected.isEmpty else { return }

        let active = selected.filter { hasActiveDownload(for: $0) }
        guard active.isEmpty else {
            errorMessage = active.count == 1
                ? "Cancel or finish the selected file’s active download before deleting it from the server."
                : "Cancel or finish the \(active.count) selected files with active downloads before deleting this batch from the server."
            return
        }

        pendingBatchDelete = selected
    }

    @MainActor
    private func deleteFromServer(_ file: IPAVaultRemoteFile) async {
        guard !deletingIDs.contains(file.id) else { return }
        guard !hasActiveDownload(for: file) else {
            errorMessage = "Cancel or finish this file’s active download before deleting it from the server."
            return
        }

        deletingIDs.insert(file.id)
        defer { deletingIDs.remove(file.id) }

        do {
            try await deleteRemoteFile(file)
            remoteFiles.removeAll { $0.id == file.id }
            selectedRemote.remove(file.id)
            pendingDelete = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func deleteSelectedFromServer(_ files: [IPAVaultRemoteFile]) async {
        guard !files.isEmpty else { return }

        let active = files.filter { hasActiveDownload(for: $0) }
        guard active.isEmpty else {
            errorMessage = "One or more selected files now has an active download. Finish or cancel those downloads and try again."
            return
        }

        var failures: [String] = []

        for file in files {
            guard !deletingIDs.contains(file.id) else { continue }
            deletingIDs.insert(file.id)

            do {
                try await deleteRemoteFile(file)
                remoteFiles.removeAll { $0.id == file.id }
                selectedRemote.remove(file.id)
            } catch {
                failures.append(file.name)
            }

            deletingIDs.remove(file.id)
        }

        if !failures.isEmpty {
            errorMessage = failures.count == 1
                ? "Couldn’t delete \(failures[0]) from the server."
                : "Couldn’t delete \(failures.count) selected files from the server."
        }
    }

    private func deleteRemoteFile(_ file: IPAVaultRemoteFile) async throws {
        var request = URLRequest(url: file.url)
        request.httpMethod = "DELETE"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "IPAVault",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The server returned an invalid response."]
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "IPAVault",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(http.statusCode)."]
            )
        }
    }

    @MainActor
    private func refreshCurrentMode() async {
        if mode == .download {
            await refreshRemoteFiles()
        } else {
            await refreshLocalFiles()
        }
    }

    @MainActor
    private func refreshRemoteFiles() async {
        guard let baseURL = normalizedServerURL else {
            errorMessage = "Enter a valid server URL in IPA Vault settings."
            remoteFiles = []
            return
        }

        loading = true
        defer { loading = false }

        do {
            var request = URLRequest(url: baseURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NSError(domain: "IPAVault", code: 1, userInfo: [NSLocalizedDescriptionKey: "The server returned an invalid response."])
            }
            guard (200..<300).contains(http.statusCode) else {
                throw NSError(domain: "IPAVault", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(http.statusCode)."])
            }

            let entries = try JSONDecoder().decode([IPAVaultNginxEntry].self, from: data)
            remoteFiles = entries.compactMap { entry in
                guard entry.type == "file",
                      entry.name.lowercased().hasSuffix(".ipa"),
                      !entry.name.hasPrefix(".ipavault-"),
                      let size = entry.size,
                      size > 0 else { return nil }
                return IPAVaultRemoteFile(
                    name: entry.name,
                    size: size,
                    url: baseURL.appendingPathComponent(entry.name, isDirectory: false)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            selectedRemote = selectedRemote.intersection(Set(remoteFiles.map(\.id)))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            if remoteFiles.isEmpty { remoteFiles = [] }
        }
    }

    @MainActor
    private func refreshLocalFiles() async {
        loading = true
        defer { loading = false }

        do {
            let directory = URL.documentsDirectory.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            localFiles = urls.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true,
                      let size = values.fileSize,
                      size > 0 else { return nil }
                return IPAVaultLocalFile(name: url.lastPathComponent, size: Int64(size), url: url)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            selectedLocal = selectedLocal.intersection(Set(localFiles.map(\.id)))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            localFiles = []
        }
    }
}

private struct IPAVaultUploadRow: View {
    let job: IPAVaultUploadJob
    let manager: IPAVaultUploadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.file.name)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                control
            }

            if case .uploading = job.state {
                ProgressView(value: job.progress)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        switch job.state {
        case .queued:
            return "Queued"
        case .uploading:
            let sent = ByteCountFormatter.string(fromByteCount: job.bytesSent, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: job.totalBytes, countStyle: .file)
            let speed = ByteCountFormatter.string(fromByteCount: Int64(job.bytesPerSecond), countStyle: .file)
            return "\(Int(job.progress * 100))% • \(sent) / \(total) • \(speed)/s"
        case .completed:
            return "Uploaded"
        case .failed(let message):
            return "Failed • \(message)"
        case .cancelled:
            return "Cancelled"
        }
    }

    @ViewBuilder
    private var control: some View {
        switch job.state {
        case .queued, .uploading:
            Button(role: .destructive) {
                manager.cancel(job.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
        case .failed:
            Button {
                manager.retry(job.id)
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
            }
            .buttonStyle(.borderless)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }
}

private struct IPAVaultSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var serverURL: String
    @Binding var concurrentFiles: Int

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://100.x.x.x:8765/", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Server")
                } footer: {
                    Text("IPA Vault uses the nginx JSON directory listing for downloads, HTTP DELETE for server cleanup, and HTTP PUT for uploads.")
                }

                Section {
                    Stepper(value: $concurrentFiles, in: 1...8) {
                        LabeledContent("Concurrent files", value: "\(concurrentFiles)")
                    }
                } header: {
                    Text("Transfers")
                } footer: {
                    Text("Applies to both IPA Vault downloads and uploads. Changing the value takes effect immediately for queued transfers; already-active files are allowed to finish.")
                }
            }
            .navigationTitle("IPA Vault Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

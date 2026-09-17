import SwiftUI

// Owns IPA Vault presentation at the tab-bar root, just like InstallSession
// owns the install drawer. Dismissing the sheet is a minimize operation: the
// Vault remains active and can be reopened from the floating pill.
final class IPAVaultPresentationSession: ObservableObject {
    static let shared = IPAVaultPresentationSession()

    @Published var isPresented = false
    @Published private(set) var isActive = false

    // Selection belongs to the Vault session, not the sheet view. SwiftUI
    // destroys/recreates the sheet when it is minimized/restored, so keeping
    // these IDs here preserves the user's working set across that lifecycle.
    @Published var selectedRemoteIDs: Set<String> = []
    @Published var selectedLocalIDs: Set<String> = []

    // One downloader instance is shared by the Downloads tab and the Vault
    // drawer so minimizing/reopening never swaps out the active transfer owner.
    let downloadManager = IPADownloadManager()

    private init() {}

    func open() {
        isActive = true
        isPresented = true
    }

    func minimize() {
        guard isActive else { return }
        isPresented = false
    }

    func close() {
        isPresented = false
        isActive = false
    }
}

// Root-level host for IPA Vault. Its behavior intentionally mirrors the
// multi-install drawer: swipe/dismiss the sheet to minimize it, then tap the
// pill above the tab bar to bring it back. Closing is explicit.
struct IPAVaultDrawerView: View {
    @ObservedObject private var session = IPAVaultPresentationSession.shared
    @ObservedObject private var installSession = InstallSession.shared

    private let _tabBarInset: CGFloat = 58

    var body: some View {
        ZStack(alignment: .bottom) {
            if session.isActive, !session.isPresented {
                _pill
                    .padding(.bottom, _pillBottomInset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: session.isPresented)
        .animation(.easeInOut(duration: 0.25), value: session.isActive)
        .sheet(isPresented: $session.isPresented, onDismiss: {
            session.minimize()
        }) {
            IPAVaultView(downloadManager: session.downloadManager)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // If the install drawer is minimized at the same time, stack the Vault pill
    // above it instead of letting the two controls occupy the same hit target.
    private var _pillBottomInset: CGFloat {
        installSession.isActive && !installSession.isDrawerPresented
            ? _tabBarInset + 52
            : _tabBarInset
    }

    private var _pill: some View {
        Button {
            session.open()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.wifi")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                Text("IPA Vault")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)

                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.16), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Restore IPA Vault")
    }
}
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

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue.main)
    }()

    private override init() {
        super.init()
    }

    func enqueue(_ files: [IPAVaultLocalFile], baseURL: URL) {
        for file in files {
            let remoteURL = baseURL.appendingPathComponent(file.name, isDirectory: false)
            let id = UUID()
            let job = IPAVaultUploadJob(
                id: id,
                file: file,
                remoteURL: remoteURL,
                state: .uploading,
                bytesSent: 0,
                totalBytes: file.size,
                bytesPerSecond: 0
            )
            jobs.insert(job, at: 0)

            var request = URLRequest(url: remoteURL)
            request.httpMethod = "PUT"
            request.timeoutInterval = 60 * 60
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(file.size), forHTTPHeaderField: "Content-Length")

            let task = session.uploadTask(with: request, fromFile: file.url)
            taskToJobID[task.taskIdentifier] = id
            samples[id] = (Date(), 0, 0)
            task.resume()
        }
    }

    func cancel(_ id: UUID) {
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
        enqueue([old.file], baseURL: old.remoteURL.deletingLastPathComponent())
    }

    func clearFinished() {
        jobs.removeAll {
            switch $0.state {
            case .completed, .cancelled: return true
            default: return false
            }
        }
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

        defer { samples.removeValue(forKey: id) }

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
    @ObservedObject private var presentationSession = IPAVaultPresentationSession.shared
    @ObservedObject private var uploadManager = IPAVaultUploadManager.shared

    @AppStorage("Ksign.IPAVault.serverURL") private var serverURL = "http://100.89.243.68:8765/"
    @AppStorage("Ksign.IPAVault.mode") private var modeRaw = IPAVaultMode.download.rawValue
    @AppStorage("Ksign.IPAVault.concurrentFiles") private var concurrentFiles = 3
    @AppStorage("Ksign.IPAVault.streamsPerFile") private var streamsPerFile = 5

    @State private var remoteFiles: [IPAVaultRemoteFile] = []
    @State private var localFiles: [IPAVaultLocalFile] = []
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
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .accessibilityLabel("Minimize IPA Vault")

                    Button {
                        presentationSession.close()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close IPA Vault")
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
                let clampedConcurrent = min(8, max(1, concurrentFiles))
                let clampedStreams = min(10, max(1, streamsPerFile))
                if concurrentFiles != clampedConcurrent {
                    concurrentFiles = clampedConcurrent
                }
                if streamsPerFile != clampedStreams {
                    streamsPerFile = clampedStreams
                }
                downloadManager.configureIPAVaultDownloads(
                    maxConcurrent: clampedConcurrent,
                    streamsPerFile: clampedStreams
                )
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
                downloadManager.configureIPAVaultDownloads(
                    maxConcurrent: clamped,
                    streamsPerFile: streamsPerFile
                )
            }
            .onChange(of: streamsPerFile) { value in
                let clamped = min(10, max(1, value))
                if value != clamped {
                    streamsPerFile = clamped
                    return
                }
                downloadManager.configureIPAVaultDownloads(
                    maxConcurrent: concurrentFiles,
                    streamsPerFile: clamped
                )
            }
            .sheet(isPresented: $showingSettings) {
                IPAVaultSettingsView(
                    serverURL: $serverURL,
                    concurrentFiles: $concurrentFiles,
                    streamsPerFile: $streamsPerFile
                )
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
                                Image(systemName: presentationSession.selectedRemoteIDs.contains(file.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(presentationSession.selectedRemoteIDs.contains(file.id) ? Color.accentColor : Color.secondary)
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
                        Button(presentationSession.selectedRemoteIDs.count == remoteFiles.count ? "Clear" : "Select All") {
                            if presentationSession.selectedRemoteIDs.count == remoteFiles.count {
                                presentationSession.selectedRemoteIDs.removeAll()
                            } else {
                                presentationSession.selectedRemoteIDs = Set(remoteFiles.map(\.id))
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
                                Image(systemName: presentationSession.selectedLocalIDs.contains(file.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(presentationSession.selectedLocalIDs.contains(file.id) ? Color.accentColor : Color.secondary)
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
                        Button(presentationSession.selectedLocalIDs.count == localFiles.count ? "Clear" : "Select All") {
                            if presentationSession.selectedLocalIDs.count == localFiles.count {
                                presentationSession.selectedLocalIDs.removeAll()
                            } else {
                                presentationSession.selectedLocalIDs = Set(localFiles.map(\.id))
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
        if mode == .download && !presentationSession.selectedRemoteIDs.isEmpty {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 10) {
                    Button {
                        downloadSelected()
                    } label: {
                        Label(
                            presentationSession.selectedRemoteIDs.count == 1 ? "Download 1" : "Download \(presentationSession.selectedRemoteIDs.count)",
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
                            presentationSession.selectedRemoteIDs.count == 1 ? "Delete 1" : "Delete \(presentationSession.selectedRemoteIDs.count)",
                            systemImage: "trash.fill"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!deletingIDs.isDisjoint(with: presentationSession.selectedRemoteIDs))
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
            }
        } else if mode == .upload && !presentationSession.selectedLocalIDs.isEmpty {
            VStack(spacing: 0) {
                Divider()
                Button {
                    uploadSelected()
                } label: {
                    Label(
                        presentationSession.selectedLocalIDs.count == 1 ? "Send 1" : "Send \(presentationSession.selectedLocalIDs.count)",
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
        if presentationSession.selectedRemoteIDs.contains(file.id) {
            presentationSession.selectedRemoteIDs.remove(file.id)
        } else {
            presentationSession.selectedRemoteIDs.insert(file.id)
        }
    }

    private func toggleLocal(_ file: IPAVaultLocalFile) {
        if presentationSession.selectedLocalIDs.contains(file.id) {
            presentationSession.selectedLocalIDs.remove(file.id)
        } else {
            presentationSession.selectedLocalIDs.insert(file.id)
        }
    }

    private func downloadSelected() {
        let selected = remoteFiles.filter { presentationSession.selectedRemoteIDs.contains($0.id) }
        let downloads = selected.map { (url: $0.url, filename: $0.name, size: $0.size) }
        downloadManager.enqueueIPAVaultDownloads(
            downloads,
            maxConcurrent: concurrentFiles,
            streamsPerFile: streamsPerFile
        )
        statusMessage = selected.count == 1
            ? "Added 1 IPA to Ksign Downloads."
            : "Added \(selected.count) IPAs to Ksign Downloads."
        presentationSession.selectedRemoteIDs.removeAll()
    }

    private func uploadSelected() {
        guard let baseURL = normalizedServerURL else {
            errorMessage = "Enter a valid server URL in IPA Vault settings."
            return
        }
        let selected = localFiles.filter { presentationSession.selectedLocalIDs.contains($0.id) }
        uploadManager.enqueue(selected, baseURL: baseURL)
        presentationSession.selectedLocalIDs.removeAll()
    }

    private func hasActiveDownload(for file: IPAVaultRemoteFile) -> Bool {
        downloadManager.downloadItems.contains { item in
            !item.isFinished && item.url == file.url
        }
    }

    private func prepareBatchDelete() {
        let selected = remoteFiles.filter { presentationSession.selectedRemoteIDs.contains($0.id) }
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
            presentationSession.selectedRemoteIDs.remove(file.id)
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
                presentationSession.selectedRemoteIDs.remove(file.id)
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

            presentationSession.selectedRemoteIDs = presentationSession.selectedRemoteIDs.intersection(Set(remoteFiles.map(\.id)))
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

            presentationSession.selectedLocalIDs = presentationSession.selectedLocalIDs.intersection(Set(localFiles.map(\.id)))
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
        case .uploading:
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
    @Binding var streamsPerFile: Int

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
                    Text("IPA Vault uses the nginx JSON directory listing and HTTP Range requests for downloads, and HTTP PUT for uploads.")
                }

                Section {
                    Stepper(value: $concurrentFiles, in: 1...8) {
                        LabeledContent("Concurrent files", value: "\(concurrentFiles)")
                    }

                    Stepper(value: $streamsPerFile, in: 1...10) {
                        LabeledContent("Streams per file", value: "\(streamsPerFile)")
                    }

                    LabeledContent(
                        "Maximum active streams",
                        value: "\(concurrentFiles * streamsPerFile)"
                    )
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("These settings apply only to IPA Vault Server → iPhone downloads into Ksign's Downloads folder. They do not change uploads, imports, or signing. Concurrent-file changes apply as paused downloads resume. Changing streams per file while a download is paused restarts that file with the new stream layout when it resumes.")
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

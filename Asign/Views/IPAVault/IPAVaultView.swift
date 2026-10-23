import SwiftUI
import NimbleExtensions

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
    @State private var installPillVisible = InstallSession.shared.isActive && !InstallSession.shared.isDrawerPresented

    private let _tabBarInset: CGFloat = 58
    private let _pillHitPadding: CGFloat = 8

    var body: some View {
        ZStack(alignment: .bottom) {
            if session.isActive, !session.isPresented {
                _pill
                    // Keep the visible capsule in place while its tap target grows.
                    .padding(.bottom, _pillBottomInset - _pillHitPadding)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: session.isPresented)
        .animation(.easeInOut(duration: 0.25), value: session.isActive)
        .onReceive(InstallSession.shared.isMinimizedPublisher) { installPillVisible = $0 }
        .sheet(isPresented: $session.isPresented, onDismiss: {
            session.minimize()
        }) {
            IPAVaultView(downloadManager: session.downloadManager)
                .nbThemeGlassSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // If the install drawer is minimized at the same time, stack the Vault pill
    // above it instead of letting the two controls occupy the same hit target.
    private var _pillBottomInset: CGFloat {
        installPillVisible
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
                    .nbThemeForeground(.accent)

                Text("IPA Vault")
                    .font(.footnote.weight(.medium))
                    .nbThemeForeground(.text)

                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.bold))
                    .nbThemeForeground(.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .nbThemeBackground(.overlaySurface, in: Capsule())
            .nbThemeOverlay(
                Capsule()
                    .nbThemeStroke(.text, opacity: 0.08, lineWidth: 0.5)
            )
            .nbThemeShadow(.shadow, radius: 10, y: 3)
            // Plain buttons need an explicit shape so gaps and transparent
            // padding restore the Vault instead of tapping a download behind it.
            .padding(_pillHitPadding)
            .contentShape(Rectangle())
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

private struct IPAVaultRemoteFile: Identifiable, Hashable, Sendable {
    let name: String
    let size: Int64
    let url: URL

    var id: String { url.absoluteString }
}

private struct IPAVaultLocalFile: Identifiable, Hashable, Sendable {
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

private struct IPAVaultUploadJob: Identifiable, Equatable {
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
        // URLSession may call back for every network buffer. Publish one
        // coherent row snapshot per sample, with a final byte update at EOF.
        guard elapsed >= 0.4 || totalBytesSent == totalBytesExpectedToSend else { return }
        let instant = Double(max(0, totalBytesSent - previous.bytes)) / max(elapsed, 0.001)
        let speed = previous.speed > 0 ? (previous.speed * 0.7 + instant * 0.3) : instant
        samples[id] = (now, totalBytesSent, speed)

        var job = jobs[index]
        job.bytesSent = totalBytesSent
        if totalBytesExpectedToSend > 0 {
            job.totalBytes = totalBytesExpectedToSend
        }
        job.bytesPerSecond = speed
        jobs[index] = job
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
    // Read only when performing an action; download progress never changes
    // the server directory or its selection UI.
    let downloadManager: IPADownloadManager
    @ObservedObject private var presentationSession = IPAVaultPresentationSession.shared
    private let uploadManager = IPAVaultUploadManager.shared

    @AppStorage("Ksign.IPAVault.serverURL") private var serverURL = "http://100.89.243.68:8765/"
    @AppStorage("Ksign.IPAVault.mode") private var modeRaw = IPAVaultMode.download.rawValue

    @AppStorage("IPAVaultDiagnosticsEnabled") private var diagnosticsEnabled = false
    @State private var remoteFiles: [IPAVaultRemoteFile] = []
    @State private var localFiles: [IPAVaultLocalFile] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
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

                Divider().nbThemeOverlay(.separator)

                if mode == .download {
                    remoteContent
                } else {
                    localContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .nbThemeCanvas(adaptsText: false)
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
                        Task { await refreshCurrentMode() }
                    } label: {
                        if loading {
                            ProgressView()
                            .nbThemeTint(.accent)
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
                await refreshCurrentMode()
            }
            .onChange(of: modeRaw) { _ in
                Task { await refreshCurrentMode() }
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
                Text("This permanently removes \(file.name) from the VPS. A copy already downloaded to Asign is not affected.")
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
                Text("This permanently removes the selected files from the VPS. Copies already downloaded to Asign are not affected.")
            }
        }
    }

    @ViewBuilder
    private var remoteContent: some View {
        if loading && remoteFiles.isEmpty {
            Spacer()
            ProgressView("Loading IPA Vault…")
            .nbThemeTint(.accent)
            Spacer()
        } else if remoteFiles.isEmpty {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.wifi")
                    .font(.system(size: 38))
                    .nbThemeForeground(.textSecondary)
                Text("No files found")
                    .font(.headline)
                    .nbThemeForeground(.text)
                Text("Check the server address or add files to the VPS folder.")
                    .font(.footnote)
                    .nbThemeForeground(.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            Spacer()
        } else {
            List {
                Group {
                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.footnote)
                            .nbThemeForeground(.textSecondary)
                            .nbThemeTextRow()
                    }
                }

                Section {
                    ForEach(remoteFiles) { file in
                        Button {
                            toggleRemote(file)
                        } label: {
                            IPAVaultFileLabel(
                                name: file.name, size: file.size,
                                isSelected: presentationSession.selectedRemoteIDs.contains(file.id)
                            )
                            .equatable()
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
                        Text("Server").nbThemeChromeForeground(.textSecondary)
                        Spacer()
                        Button(presentationSession.selectedRemoteIDs.count == remoteFiles.count ? "Clear" : "Select All") {
                            if presentationSession.selectedRemoteIDs.count == remoteFiles.count {
                                presentationSession.selectedRemoteIDs.removeAll()
                            } else {
                                presentationSession.selectedRemoteIDs = Set(remoteFiles.map(\.id))
                            }
                        }
                        .nbThemeForeground(.accent)
                    }
                }
                }
                .nbThemeRow(adaptsText: false)
            }
            .listStyle(.insetGrouped)
            .nbThemeCanvas(rendersAurora: false, adaptsText: false)
            .nbThemeTextViewport()
            .refreshable { await refreshRemoteFiles() }
        }
    }

    @ViewBuilder
    private var localContent: some View {
        List {
            Group {
            IPAVaultUploadSection()

            Section {
                if localFiles.isEmpty {
                    Text("No files are in Asign's Downloads folder.")
                        .nbThemeForeground(.textSecondary)
                        .nbThemeTextRow()
                } else {
                    ForEach(localFiles) { file in
                        Button {
                            toggleLocal(file)
                        } label: {
                            IPAVaultFileLabel(
                                name: file.name, size: file.size,
                                isSelected: presentationSession.selectedLocalIDs.contains(file.id)
                            )
                            .equatable()
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                HStack {
                    Text("Asign Downloads").nbThemeChromeForeground(.textSecondary)
                    Spacer()
                    if !localFiles.isEmpty {
                        Button(presentationSession.selectedLocalIDs.count == localFiles.count ? "Clear" : "Select All") {
                            if presentationSession.selectedLocalIDs.count == localFiles.count {
                                presentationSession.selectedLocalIDs.removeAll()
                            } else {
                                presentationSession.selectedLocalIDs = Set(localFiles.map(\.id))
                            }
                        }
                        .nbThemeForeground(.accent)
                    }
                }
            }
            }
            .nbThemeRow(adaptsText: false)
        }
        .listStyle(.insetGrouped)
        .nbThemeCanvas(rendersAurora: false, adaptsText: false)
        .nbThemeTextViewport()
        .refreshable { await refreshLocalFiles() }
    }

    @ViewBuilder
    private var actionBar: some View {
        if mode == .download && !presentationSession.selectedRemoteIDs.isEmpty {
            VStack(spacing: 0) {
                Divider().nbThemeOverlay(.separator)
                Toggle("Tuning logs", isOn: $diagnosticsEnabled)
                    .font(.subheadline)
                    .nbThemeForeground(.text)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .accessibilityHint("Save detailed download diagnostics in the Asign Logs folder")
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
                .nbThemeBackground(.overlaySurface)
            }
        } else if mode == .upload && !presentationSession.selectedLocalIDs.isEmpty {
            VStack(spacing: 0) {
                Divider().nbThemeOverlay(.separator)
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
                .nbThemeBackground(.overlaySurface)
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
        downloadManager.enqueueIPAVaultDownloads(downloads)
        statusMessage = selected.count == 1
            ? "Added 1 file to Asign Downloads."
            : "Added \(selected.count) files to Asign Downloads."
        presentationSession.selectedRemoteIDs.removeAll()
    }

    private func uploadSelected() {
        guard let baseURL = normalizedServerURL else {
            errorMessage = "Enter a valid IPA Vault server address."
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
            errorMessage = "Enter a valid IPA Vault server address."
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

            remoteFiles = try await Task.detached(priority: .userInitiated) {
                let entries = try JSONDecoder().decode([IPAVaultNginxEntry].self, from: data)
                return entries.compactMap { entry in
                    guard entry.type == "file",
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
            }.value

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
            localFiles = try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let urls = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )

                return urls.compactMap { url in
                    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                          values.isRegularFile == true,
                          let size = values.fileSize,
                          size > 0 else { return nil }
                    return IPAVaultLocalFile(name: url.lastPathComponent, size: Int64(size), url: url)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }.value

            presentationSession.selectedLocalIDs = presentationSession.selectedLocalIDs.intersection(Set(localFiles.map(\.id)))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            localFiles = []
        }
    }
}

// Independent row inputs keep selection changes from rebuilding unchanged
// label/geometry subtrees or formatting every file size again.
private struct IPAVaultFileLabel: View, Equatable {
    let name: String
    let size: Int64
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .nbThemeForeground(isSelected ? .accent : .textSecondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .nbThemeForeground(.text)
                    .lineLimit(2)
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.caption)
                    .nbThemeForeground(.textSecondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .nbThemeTextRow()
    }
}

// Transfer progress invalidates this section, leaving the selectable directory
// and its toolbar out of the upload update path.
private struct IPAVaultUploadSection: View {
    @ObservedObject private var manager = IPAVaultUploadManager.shared

    var body: some View {
        if !manager.jobs.isEmpty {
            Section {
                ForEach(manager.jobs) { job in
                    IPAVaultUploadRow(job: job, manager: manager)
                        .equatable()
                }
                if manager.jobs.contains(where: {
                    switch $0.state {
                    case .completed, .cancelled: return true
                    default: return false
                    }
                }) {
                    Button("Clear Finished") { manager.clearFinished() }
                        .nbThemeForeground(.accent)
                        .nbThemeTextRow()
                }
            } header: {
                Text("Uploads").nbThemeChromeForeground(.textSecondary)
            }
        }
    }
}

private struct IPAVaultUploadRow: View, Equatable {
    let job: IPAVaultUploadJob
    let manager: IPAVaultUploadManager

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.job == rhs.job && lhs.manager === rhs.manager
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.file.name)
                        .nbThemeForeground(.text)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .nbThemeForeground(.textSecondary)
                }
                Spacer()
                control
            }

            if case .uploading = job.state {
                ProgressView(value: job.progress)
                .nbThemeTint(.accent)
            }
        }
        .padding(.vertical, 2)
        .nbThemeTextRow()
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
                    .nbThemeForeground(.danger)
            }
            .buttonStyle(.borderless)
        case .failed:
            Button {
                manager.retry(job.id)
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .nbThemeForeground(.accent)
            }
            .buttonStyle(.borderless)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .nbThemeForeground(.success)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .nbThemeForeground(.textSecondary)
        }
    }
}

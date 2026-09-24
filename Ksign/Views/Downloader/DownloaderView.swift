//
//  DownloaderView.swift
//  Ksign
//
//  Created by Nagata Asami on 5/24/25.
//

import SwiftUI
import NimbleExtensions
import UniformTypeIdentifiers
import NimbleViews
import UIKit

struct DownloaderView: View {
    // Inspector-only sample state. Normal Downloads instances never create a
    // synthetic download or change the shared download manager.
    let inspectorSampleDownloadStatus: Bool

    init(inspectorSampleDownloadStatus: Bool = false) {
        self.inspectorSampleDownloadStatus = inspectorSampleDownloadStatus
    }

    @ObservedObject private var themes = NBThemeManager.shared
    @ObservedObject private var downloadManager = IPAVaultPresentationSession.shared.downloadManager
    @StateObject private var libraryManager = DownloadManager.shared
    
    @State private var selectedItem: DownloadItem?
    @State private var webViewURL: URL?
    @State private var shareItems: [Any] = []
    @State private var showDocumentPicker = false
    @State private var fileToExport: URL?
    @State private var cryptCheckReports: CryptCheckReportCollection?
    @State private var cryptCheckRunning = false
    @State private var _searchText = ""

    @State private var _isEditMode: EditMode = .inactive
    @State private var _selectedDownloads: Set<UUID> = []
    // Swallows a second tap that lands before the first one's transition has
    // settled — see ToolbarTapGate in LibraryView.swift.
    @State private var _tapGate = ToolbarTapGate()
    
    private var filteredDownloadItems: [DownloadItem] {
        let items = downloadManager.finishedItems
        if _searchText.isEmpty {
            return items
        } else {
            return items.filter { $0.title.localizedCaseInsensitiveContains(_searchText) }
        }
    }

    private var hasActiveIPAVaultDownloads: Bool {
        downloadManager.activeItems.contains { $0.isIPAVaultDownload }
    }

    private var ipavaultLiveThroughputText: String {
        guard downloadManager.ipavaultAdaptiveSpeedBPS > 0 else {
            return "Measuring…"
        }
        return String(format: "%.1f MB/s", downloadManager.ipavaultAdaptiveSpeedBPS / 1_000_000)
    }

    private var ipavaultActiveStreamsText: String {
        let count = downloadManager.ipavaultAdaptiveStreamCount
        return "\(count) stream\(count == 1 ? "" : "s")"
    }

    // Shared by a real IPA Vault download and the inspector's non-networked
    // sample, so the inspected separator has precisely the production layout.
    private func ipaVaultStatusRow(speed: String, streams: String, isSample: Bool = false) -> some View {
        HStack(spacing: 8) {
            Label("IPA Vault", systemImage: "externaldrive.badge.wifi")
                .fontWeight(.semibold)
            Spacer()
            Text(speed).monospacedDigit()
            Text("•")
                .foregroundStyle(NBHalloween.textTertiary)
                .nbThemeInspectorTarget(.textTertiary)
            Text(streams).monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(NBHalloween.textSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isSample ? "IPA Vault sample download status" : "IPA Vault live download status")
        .accessibilityValue("\(speed), \(streams)")
    }

    var body: some View {
        let _ = themes.previewRevision
        NBNavigationView(.localized("Downloads")) {
            List {
                if inspectorSampleDownloadStatus && !hasActiveIPAVaultDownloads {
                    NBSection("Downloading", secondary: "Sample") {
                        ipaVaultStatusRow(speed: "12.4 MB/s", streams: "4 streams", isSample: true)
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.down.document")
                                .foregroundStyle(NBHalloween.accent)
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Example.ipa")
                                Text("62 MB / 100 MB (62%)")
                                    .font(.caption)
                                    .foregroundStyle(NBHalloween.textSecondary)
                            }
                            Spacer()
                            ProgressView(value: 0.62)
                                .frame(width: 52)
                                .tint(NBHalloween.warning)
                        }
                        Text("Inspector sample only · no download started")
                            .font(.caption2)
                            .foregroundStyle(NBHalloween.textSecondary)
                    }
                }

                if libraryManager.isImporting {
                    // One static row for the whole batch.
                    //
                    // This section used to render `libraryManager.downloads`
                    // directly. A bulk import appends a Download per app and
                    // removes it on completion, so importing 60 apps meant 60
                    // row inserts + 60 row deletes at the TOP of the list —
                    // shoving everything below it up and down — plus the whole
                    // section collapsing and reappearing whenever the array
                    // briefly emptied between apps, plus a re-render per
                    // extraction-progress tick. That is the flickering.
                    //
                    // The finished list underneath is only a selection surface
                    // during an import, so it now stays completely still.
                    NBSection(.localized("Importing")) {
                        // Imports normally replace the active-download section.
                        // Keep the inspected live status visible in the copy.
                        if inspectorSampleDownloadStatus && hasActiveIPAVaultDownloads {
                            ipaVaultStatusRow(speed: ipavaultLiveThroughputText,
                                              streams: ipavaultActiveStreamsText)
                        }
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(.localized("Importing apps, please wait"))
                                .foregroundStyle(NBHalloween.textSecondary)
                            Spacer()
                        }
                    }
                } else if !libraryManager.downloads.isEmpty || !downloadManager.activeItems.isEmpty {
                    NBSection(.localized("Downloading"), secondary: (libraryManager.downloads.count + downloadManager.activeItems.count).description) {
                        if hasActiveIPAVaultDownloads {
                            ipaVaultStatusRow(speed: ipavaultLiveThroughputText,
                                              streams: ipavaultActiveStreamsText)
                        }

                        ForEach(libraryManager.downloads) { download in
                            AppStoreDownloadItemRow(download: download)
                        }
                        ForEach(downloadManager.activeItems) { item in
                            DownloadItemRow(
                                item: item,
                                shareItems: $shareItems,
                                isSelected: false,
                                onToggleSelection: {},
                                selectable: false,
                                importIpaToLibrary: { item in importIpaToLibrary(item) },
                                exportToFiles: { item in exportToFiles(item) },
                                cryptCheck: { item in runCryptCheck(item) },
                                pauseResumeDownload: { item in togglePauseResume(item) },
                                deleteItem: { item in deleteItem(item) }
                            )
                        }
                    }
                }
                
                NBSection(.localized("Downloaded"), secondary: filteredDownloadItems.count.description) {
                    ForEach(filteredDownloadItems) { item in
                        DownloadItemRow(
                            item: item,
                            shareItems: $shareItems,
                            isSelected: _selectedDownloads.contains(item.id),
                            onToggleSelection: { _toggleSelection(for: item) },
                            importIpaToLibrary: { item in importIpaToLibrary(item) },
                            exportToFiles: { item in exportToFiles(item) },
                            cryptCheck: { item in runCryptCheck(item) },
                            pauseResumeDownload: { item in togglePauseResume(item) },
                            deleteItem: { item in deleteItem(item) }
                        )
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if cryptCheckRunning {
                    ProgressView("Running Crypt Check…")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(NBHalloween.overlaySurface, in: RoundedRectangle(cornerRadius: 14))
                } else if !inspectorSampleDownloadStatus && downloadManager.finishedItems.isEmpty && downloadManager.activeItems.isEmpty && libraryManager.downloads.isEmpty {
                    if #available(iOS 17, *) {
                        ContentUnavailableView {
                            Label(.localized("No downloaded IPAs"), systemImage: "square.and.arrow.down.fill")
                            .foregroundStyle(NBHalloween.heading)
                        } description: {
                            Text(.localized("Get started by downloading your first IPA file."))
                            .foregroundStyle(NBHalloween.textSecondary)
                        } actions: {
                            Button {
                                _addDownload()
                            } label: {
                                Text("Add Download").bg()
                            }
                        }
                    }
                }
            }
            .searchable(text: $_searchText, placement: .platform())
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    if !downloadManager.finishedItems.isEmpty || _isEditMode.isEditing {
                        _editButton
                    }
                    if _isEditMode.isEditing {
                        _selectAllButton
                    }
                }

                // Always present, edit mode or not. See the long note on the
                // matching group in LibraryView: this used to be two toolbar
                // *items* appearing and a third disappearing whenever edit mode
                // flipped, and SwiftUI drops or strands real UIBarButtonItems
                // when they come and go during the bar's own animation. One
                // stable group whose contents change avoids that entirely.
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if _isEditMode.isEditing {
                        _barButton(
                            "tray.and.arrow.down.fill",
                            enabled: !_selectedDownloads.isEmpty
                        ) {
                            _bulkImportSelected()
                        }
                        _barButton("lock.open", enabled: !_selectedDownloads.isEmpty && !cryptCheckRunning) {
                            _bulkCryptCheckSelected()
                        }
                        _barButton("trash", enabled: !_selectedDownloads.isEmpty) {
                            _bulkDeleteSelected()
                        }
                    } else {
                        Button {
                            IPAVaultPresentationSession.shared.open()
                        } label: {
                            Image(systemName: "externaldrive.badge.wifi")
                                .foregroundStyle(NBHalloween.accent)
                        }
                        .accessibilityLabel("IPA Vault")

                        Button {
                            _addDownload()
                        } label: {
                            Image(systemName: "plus")
                                .foregroundStyle(NBHalloween.accent)
                        }
                    }
                }
            }
            .onChange(of: _isEditMode) { state in
                if !state.isEditing {
                    _selectedDownloads.removeAll()
                }
            }
            .onChange(of: libraryManager.downloads.count) { _ in
                // Importing adds/removes entries in `downloads` too. Don't let
                // that rebuild and reorder this list — it only needs to refresh
                // when a real download finishes, not while importing.
                guard !inspectorSampleDownloadStatus, !libraryManager.isImporting else { return }
                downloadManager.loadDownloadedIPAs()
            }
            // IPADownloadManager publishes its own completed rows. Rescanning
            // those files here caused a second list update while SwiftUI was
            // moving the last row out of the disappearing Downloading section.
            .fullScreenCover(item: $webViewURL) { url in
                webViewSheet(url: url)
            }
            .fullScreenCover(item: $cryptCheckReports) { reports in
                CryptCheckReportView(reportURLs: reports.reportURLs)
            }
            .sheet(isPresented: $showDocumentPicker) {
                documentPickerSheet
            }
            // Must be the outermost modifier so the toolbar's EditButton and
            // the list rows bind to the SAME edit mode. Placed earlier, the
            // toolbar would toggle a different (default) edit mode and the
            // rows would never see it change.
            .environment(\.editMode, $_isEditMode)
        }
        // The inspector displays shared live data, but its controls must not
        // mutate downloads or open workflows while a color is being edited.
        .disabled(inspectorSampleDownloadStatus)
    }
}


// MARK: - Alert & Sheet Content
private extension DownloaderView {
    
    @ViewBuilder
    var actionSheetContent: some View {
        if let selectedItem = selectedItem {
            Button("Share") {
                shareItem(selectedItem)
            }
            
            Button("Import to Library") {
                importIpaToLibrary(selectedItem)
            }
            
            Button("Export to Files App") {
                exportToFiles(selectedItem)
            }
            
            Button("Delete", role: .destructive) {
                deleteItem(selectedItem)
            }
            
            Button("Cancel", role: .cancel) {}
        }
    }
    
    func webViewSheet(url: URL) -> some View {
        WebViewSheet(
            downloadManager: downloadManager,
            url: url,
        )
    }
    
    @ViewBuilder
    var documentPickerSheet: some View {
        if let fileURL = fileToExport {
            FileExporterRepresentableView(
                urlsToExport: [fileURL],
                asCopy: true,
                useLastLocation: false,
                onCompletion: { _ in
                    showDocumentPicker = false
                }
            )
        }
    }

}

// MARK: - Action Handlers
private extension DownloaderView {
    func _addDownload() {
        UIAlertController.showAlertWithTextBox(
            title: .localized("Enter URL"),
            message: .localized("""
Enter the URL of the website containing the IPA file (Direct install/ITMS Services) or URL to the IPA file, supported: 
- https://example.com
- itms-services://?url=https://example.com
- https://example.com/app.ipa
"""),
            textFieldPlaceholder: .localized("https://example.com"),
            submit: .localized("OK"),
            cancel: .localized("Cancel"),
            onSubmit: { url in
                handleURLInput(url: url)
            }
        )
    }

    func handleURLInput(url: String) {
        guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        var finalUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalUrl.lowercased().hasPrefix("http://") && !finalUrl.lowercased().hasPrefix("https://") {
            finalUrl = "https://" + finalUrl
        }
        
        guard let validUrl = URL(string: finalUrl) else {
            UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Invalid URL format"))
            return
        }
        
        print(validUrl)
        
        if downloadManager.isIPAFile(validUrl) {
            downloadManager.checkFileTypeAndDownload(url: validUrl) { result in
                switch result {
                case .success:
                    UIAlertController.showAlertWithOk(title: .localized("Success"), message: .localized("The IPA file is being downloaded!\nYou can close this window or download more!"))
                case .failure(let error):
                    UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
                }
            }
        } else {
            print("validUrl: \(validUrl)")
            webViewURL = validUrl
        }
    }
    
    func shareItem(_ item: DownloadItem) {
        shareItems = [item.localPath]
        UIActivityViewController.show(activityItems: shareItems)
    }
    
    private func importIpaToLibrary(_ file: DownloadItem) {
        let id = "FeatherManualDownload_\(UUID().uuidString)"
        libraryManager.beginImport()
        let download = self.libraryManager.startArchive(from: file.url, id: id)
        libraryManager.handlePachageFile(url: file.url, dl: download) { err in
            DispatchQueue.main.async {
                if (err != nil) {
                    UIAlertController.showAlertWithOk(
                        title: .localized("Error"),
                        message: .localized("Whoops!, something went wrong when extracting the file. \nMaybe try switching the extraction library in the settings?"),
                    )
                }
                if let index = libraryManager.getDownloadIndex(by: download.id) {
                    libraryManager.downloads.remove(at: index)
                }
                // Clear on the next runloop so the removal's onChange is still
                // seen as "importing" and doesn't reload the list.
                DispatchQueue.main.async { libraryManager.endImport() }
            }
        }
    }
    
    func exportToFiles(_ item: DownloadItem) {
        fileToExport = item.localPath
        showDocumentPicker = true
    }

    func runCryptCheck(_ item: DownloadItem) {
        runCryptChecks([item])
    }

    func runCryptChecks(_ items: [DownloadItem]) {
        let finishedItems = items.filter(\.isFinished)
        guard !finishedItems.isEmpty, !cryptCheckRunning else { return }
        cryptCheckRunning = true

        DispatchQueue.global(qos: .userInitiated).async {
            var reportURLs: [URL] = []

            do {
                for item in finishedItems {
                    let reportURL = try CryptCheckAnalyzer.generateReport(for: item.localPath)
                    reportURLs.append(reportURL)
                }

                DispatchQueue.main.async {
                    cryptCheckRunning = false
                    cryptCheckReports = CryptCheckReportCollection(reportURLs: reportURLs)
                }
            } catch {
                reportURLs.forEach { try? FileManager.default.removeItem(at: $0) }
                DispatchQueue.main.async {
                    cryptCheckRunning = false
                    UIAlertController.showAlertWithOk(
                        title: "Crypt Check",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    func togglePauseResume(_ item: DownloadItem) {
        guard item.isIPAVaultDownload, !item.isFinished else { return }
        if item.isPaused {
            downloadManager.resumeIPAVaultDownload(item)
        } else {
            downloadManager.pauseIPAVaultDownload(item)
        }
    }
    
    func deleteItem(_ item: DownloadItem) {
        if !item.isFinished {
            downloadManager.cancelDownload(item)
            return
        }
        
        do {
            try FileManager.default.removeItem(at: item.localPath)
            
            // Not animated. A spring around a List row removal is the
            // animated performBatchUpdates path that has been tripping the
            // watchdog; during a bulk delete it ran once per item.
            if let index = downloadManager.downloadItems.firstIndex(where: { $0.id == item.id }) {
                downloadManager.downloadItems.remove(at: index)
            }
        } catch {
            UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
        }
    }
}

// MARK: - Multi-select (Edit mode)
private extension DownloaderView {
    // Select All targets the currently-visible finished downloads.
    var _allDownloadsSelected: Bool {
        let ids = filteredDownloadItems.map { $0.id }
        return !ids.isEmpty && ids.allSatisfy { _selectedDownloads.contains($0) }
    }

    // Replaces `EditButton()`. See the long note on the matching property in
    // LibraryView.swift: `EditButton` mutates the editMode environment value
    // itself, so no re-entrancy guard can intercept its tap. Writing the toggle
    // out by hand puts it behind `_tapGate` like every other bar control, which
    // is what allows `.disabled` — and the strandable UIBarButtonItem enabled
    // state behind it — to be gone from this file.
    var _editButton: some View {
        Button {
            guard _tapGate.allow("edit") else { return }
            _isEditMode = _isEditMode.isEditing ? .inactive : .active
        } label: {
            // `String.localized` and `verbatim:` are both spelled out on purpose.
            // Bare `.localized` is ambiguous here — String and LocalizedStringKey
            // both provide it — and `Text` is overloaded on exactly that pair, so
            // the ternary has nothing to infer from. The lookup has already
            // happened by then, hence `verbatim:` rather than a second one.
            Text(verbatim: _isEditMode.isEditing ? String.localized("Done") : String.localized("Edit"))
                .foregroundStyle(NBHalloween.accent)
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    // See LibraryView for the reasoning: no `.disabled()` on a nav-bar button,
    // because that state lives on the UIBarButtonItem and can be left stuck
    // greyed-out when the bar rebuilds mid-animation. Dim it and refuse the tap
    // in the action instead — same behaviour, nothing to get stranded.

    @ViewBuilder
    func _barButton(
        _ systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard enabled, _tapGate.allow(systemImage) else { return }
            action()
        } label: {
            Image(systemName: systemImage)
                .foregroundStyle(NBHalloween.accent)
                .opacity(enabled ? 1 : 0.3)
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    // Drawn from shapes, not swapped between two SF Symbols — see
    // SelectionCheckIcon in LibraryView.swift for why.
    var _selectAllButton: some View {
        Button {
            // The gate is the fix for the reproducible case: tap, then tap again
            // mid-transition. The second tap is dropped instead of restarting the
            // transition partway through and stranding the button.
            guard !filteredDownloadItems.isEmpty, _tapGate.allow("selectAll") else { return }
            _toggleSelectAllDownloads()
        } label: {
            SelectionCheckIcon(isSelected: _allDownloadsSelected)
                .opacity(filteredDownloadItems.isEmpty ? 0.3 : 1)
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    func _toggleSelectAllDownloads() {
        let ids = filteredDownloadItems.map { $0.id }
        // No withAnimation: this flips every visible row at once, and
        // animating that means a spring-animated batch update over the
        // whole list for a single button press.
        if _allDownloadsSelected {
            _selectedDownloads.subtract(ids)
        } else {
            _selectedDownloads.formUnion(ids)
        }
    }

    func _toggleSelection(for item: DownloadItem) {
        if _selectedDownloads.contains(item.id) {
            _selectedDownloads.remove(item.id)
        } else {
            _selectedDownloads.insert(item.id)
        }
    }

    func _bulkCryptCheckSelected() {
        let items = downloadManager.finishedItems.filter { _selectedDownloads.contains($0.id) }
        guard !items.isEmpty else { return }
        _selectedDownloads.removeAll()
        _isEditMode = .inactive
        runCryptChecks(items)
    }

    // Keep enough tasks in flight to feed the global archive-memory gate.
    // The coordinator, not this view, decides how many may extract at once.
    func _bulkImportSelected() {
        let items = downloadManager.finishedItems.filter { _selectedDownloads.contains($0.id) }
        guard !items.isEmpty else { return }
        _selectedDownloads.removeAll()

        Task {
            // Register the whole batch up front so the header can say how many
            // apps are actually left, not just how many are extracting right
            // now. Each task checks itself in as it starts.
            // Mark importing for the whole batch. Every add/remove this batch
            // makes to `downloads` happens while this is set, so the finished
            // list ignores all of it and stays exactly as it was.
            let token = await MainActor.run { () -> UUID in
                DownloadManager.shared.beginImport()
                return DownloadManager.shared.beginImportBatch(count: items.count)
            }

            await withTaskGroup(of: Void.self) { group in
                var next = 0
                let queueDepth = ArchiveMemoryCoordinator.admissionCeiling
                let initial = min(queueDepth, items.count)
                while next < initial {
                    let item = items[next]; next += 1
                    group.addTask { await Self._importOneDownload(item, token: token) }
                }
                while await group.next() != nil {
                    if next < items.count {
                        let item = items[next]; next += 1
                        group.addTask { await Self._importOneDownload(item, token: token) }
                    }
                }
            }

            // Clear importing only after every task has finished and removed its
            // row — so the trailing count changes are ignored too, and the list
            // never reloads as a result of the import.
            await MainActor.run {
                DownloadManager.shared.endImportBatch(token)
                DownloadManager.shared.endImport()
            }
        }
    }

    // Static + shared manager so the task-group closures don't capture the
    // view. Mirrors importIpaToLibrary but awaits so it can be queued.
    static func _importOneDownload(_ file: DownloadItem, token: UUID) async {
        let manager = DownloadManager.shared
        let id = "FeatherManualDownload_\(UUID().uuidString)"
        let dl = await MainActor.run { () -> Download in
            // Check in and create the `Download` in the same main-actor hop,
            // so this item is never counted as both waiting and in flight.
            manager.importDidStart(token)
            return manager.startArchive(from: file.url, id: id)
        }

        do {
            try await manager.handlePachageFile(
                url: file.url,
                dl: dl,
                liveActivityBatchToken: token
            )
        } catch {
            await MainActor.run {
                UIAlertController.showAlertWithOk(
                    title: .localized("Error"),
                    message: .localized("Whoops!, something went wrong when extracting the file. \nMaybe try switching the extraction library in the settings?")
                )
            }
        }

        await MainActor.run {
            if let index = manager.getDownloadIndex(by: dl.id) {
                manager.downloads.remove(at: index)
            }
        }
    }

    func _bulkDeleteSelected() {
        let items = downloadManager.finishedItems.filter { _selectedDownloads.contains($0.id) }
        guard !items.isEmpty else { return }
        // Clear the selection first, then delete unanimated. Previously this
        // nested a spring animation around N deletes that each already had
        // their own animation inside deleteItem.
        _selectedDownloads.removeAll()
        for item in items {
            deleteItem(item)
        }
    }
}

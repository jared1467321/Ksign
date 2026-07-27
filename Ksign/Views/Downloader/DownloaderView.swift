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
    @StateObject private var downloadManager = IPADownloadManager()
    @StateObject private var libraryManager = DownloadManager.shared
    
    @State private var selectedItem: DownloadItem?
    @State private var webViewURL: URL?
    @State private var shareItems: [Any] = []
    @State private var showDocumentPicker = false
    @State private var fileToExport: URL?
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

    var body: some View {
        NBNavigationView(.localized("Downloads")) {
            List {
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
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(.localized("Importing apps, please wait"))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                } else if !libraryManager.downloads.isEmpty || !downloadManager.activeItems.isEmpty {
                    NBSection(.localized("Downloading"), secondary: (libraryManager.downloads.count + downloadManager.activeItems.count).description) {
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
                            deleteItem: { item in deleteItem(item) }
                        )
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if downloadManager.finishedItems.isEmpty && downloadManager.activeItems.isEmpty && libraryManager.downloads.isEmpty {
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
                        _barButton("trash", enabled: !_selectedDownloads.isEmpty) {
                            _bulkDeleteSelected()
                        }
                    } else {
                        Button {
                            _addDownload()
                        } label: {
                            Image(systemName: "plus")
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
                guard !libraryManager.isImporting else { return }
                downloadManager.loadDownloadedIPAs()
            }
            .onChange(of: downloadManager.activeItems.count) { _ in
                // Same guard as the one above: never rescan the disk and
                // reorder the list while an import is running.
                guard !libraryManager.isImporting else { return }
                downloadManager.loadDownloadedIPAs()
            }
            .fullScreenCover(item: $webViewURL) { url in
                webViewSheet(url: url)
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

    // Imports every selected download, at most 2 at a time so a big batch
    // doesn't kick off all the extractions at once and freeze the app.
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
                let maxConcurrent = 2
                let initial = min(maxConcurrent, items.count)
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
            try await manager.handlePachageFile(url: file.url, dl: dl)
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

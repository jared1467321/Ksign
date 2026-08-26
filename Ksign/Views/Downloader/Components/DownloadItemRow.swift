//
//  DownloadItemRow.swift
//  Ksign
//
//  Created by Nagata Asami on 5/24/25.
//

import SwiftUI
import AltSourceKit
import NimbleExtensions

// Download Item Row
struct DownloadItemRow: View {
    @Environment(\.editMode) private var editMode
    let item: DownloadItem
    @Binding var shareItems: [Any]
    /// Just this row's selection state. This was a binding to the whole
    /// `Set<UUID>`, which made every visible row depend on the entire
    /// selection — one tap invalidated all of them, and in a `List` that is
    /// an N-row UICollectionView batch update per tap.
    var isSelected: Bool
    /// Selection is owned by DownloaderView; the row just reports the tap.
    var onToggleSelection: () -> Void
    var selectable: Bool = true
    var importIpaToLibrary: (DownloadItem) -> Void
    var exportToFiles: (DownloadItem) -> Void
    var cryptCheck: (DownloadItem) -> Void
    var deleteItem: (DownloadItem) -> Void

    @State private var showingConfirmationDialog = false

    init(
        item: DownloadItem,
        shareItems: Binding<[Any]>,
        isSelected: Bool,
        onToggleSelection: @escaping () -> Void,
        selectable: Bool = true,
        importIpaToLibrary: @escaping (DownloadItem) -> Void,
        exportToFiles: @escaping (DownloadItem) -> Void,
        cryptCheck: @escaping (DownloadItem) -> Void,
        deleteItem: @escaping (DownloadItem) -> Void
    ) {
        self.item = item
        self._shareItems = shareItems
        self.isSelected = isSelected
        self.onToggleSelection = onToggleSelection
        self.selectable = selectable
        self.importIpaToLibrary = importIpaToLibrary
        self.exportToFiles = exportToFiles
        self.cryptCheck = cryptCheck
        self.deleteItem = deleteItem
    }

    // Only finished, selectable rows participate in multi-select.
    private var _isEditing: Bool {
        editMode?.wrappedValue == .active && selectable && item.isFinished
    }

    private var _isSelected: Bool { isSelected }

    private func _toggleSelection() {
        onToggleSelection()
    }
    
    var body: some View {
        HStack(spacing: 12) {
            if _isEditing {
                Button {
                    _toggleSelection()
                } label: {
                    Image(systemName: _isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(_isSelected ? .accentColor : .secondary)
                        .font(.title2)
                }
                .buttonStyle(.borderless)
            }
            if item.isFinished {
                Image(systemName: "doc.zipper")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            } else {
                if #available(iOS 17.0, *) {
                    Image(systemName: "arrow.down.document")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                        .symbolEffect(.pulse)
                } else {
                    Image(systemName: "arrow.down.document")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)
                
                Text(item.isFinished ? item.formattedFileSize : item.progressText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if !item.isFinished {
                ZStack {
                    Circle()
                        .trim(from: 0, to: item.progress)
                        // In progress, so `warning` rather than the accent. A
                        // download is the most common non-idle state in the app,
                        // which makes this the ring most likely to actually put
                        // orange on screen day to day.
                        .stroke(NBHalloween.warning, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 31, height: 31)
                        .animation(.smooth, value: item.progress)

                    Image(systemName: item.progress >= 0.75 ? "archivebox" : "square.fill")
                        .foregroundStyle(NBHalloween.warning)
                        .font(.footnote).bold()
                }
                .onTapGesture {
                    if item.progress <= 0.75 {
                        deleteItem(item)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if _isEditing {
                _toggleSelection()
            } else if item.isFinished {
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
                showingConfirmationDialog = true
            }
        }
        .confirmationDialog(
            item.title,
            isPresented: $showingConfirmationDialog,
            titleVisibility: .visible
        ) {
            fileConfirmationDialogButtons()
        }
        .contextMenu {
            if !_isEditing {
                fileConfirmationDialogButtons()
            }
        }
        .swipeActions(edge: .trailing) {
            if !_isEditing {
                swipeActions()
            }
        }
    }
    
    @ViewBuilder
    private func fileConfirmationDialogButtons() -> some View {
        Button {
            shareItems = [item.localPath]
            UIActivityViewController.show(activityItems: shareItems)
        } label: {
            Label(.localized("Share"), systemImage: "square.and.arrow.up")
        }
        
        Button {
            importIpaToLibrary(item)
        } label: {
            Label(.localized("Import to Library"), systemImage: "square.grid.2x2.fill")
        }
        
        Button {
            exportToFiles(item)
        } label: {
            Label(.localized("Export to Files App"), systemImage: "square.and.arrow.up.fill")
        }

        if item.isFinished {
            Button {
                cryptCheck(item)
            } label: {
                Label("Crypt Check", systemImage: "lock.open")
            }
        }
        
        Button(role: .destructive) {
            deleteItem(item)
        } label: {
            Label(.localized("Delete"), systemImage: "trash")
        }
    }

    @ViewBuilder
    private func swipeActions() -> some View {
        Button(role: .destructive) {
            // Not animated: deleteItem mutates the backing array, and
            // animating a List row removal puts it on UIKit's animated
            // performBatchUpdates path.
            deleteItem(item)
        } label: {
            Label(.localized("Delete"), systemImage: "trash")
        }

        Button(role: .cancel) {
            importIpaToLibrary(item)
        } label: {
            Label(.localized("Import"), systemImage: "square.grid.2x2.fill")
        }
    }
}


struct AppStoreDownloadItemRow: View {
    @ObservedObject var download: Download
//    let app: ASRepository.App
    
    var body: some View {
        HStack(spacing: 12) {
            if #available(iOS 17.0, *) {
                Image(systemName: download.unpackageProgress > 0 ? "doc.zipper" : "arrow.down.document")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                    .symbolEffect(.pulse)
            } else {
                Image(systemName: download.unpackageProgress > 0 ? "doc.zipper" : "arrow.down.document")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(download.fileName)
                    .font(.body)
                    .lineLimit(1)
                
                Text(download.progressText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            ZStack {
                Circle()
                    .trim(from: 0, to: download.overallProgress)
                    .stroke(NBHalloween.warning, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 31, height: 31)
                    .animation(.smooth, value:  download.overallProgress)

                Image(systemName: download.overallProgress >= 0.75 ? "archivebox" : "square.fill")
                    .foregroundStyle(NBHalloween.warning)
                    .font(.footnote).bold()
                }
                .onTapGesture {
                    if download.overallProgress <= 0.75 {
                        DownloadManager.shared.cancelDownload(download)
                    }
                }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

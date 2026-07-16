//
//  DownloadItemRow.swift
//  Ksign
//
//  Created by Nagata Asami on 5/24/25.
//

import SwiftUI
import AltSourceKit

// Download Item Row
struct DownloadItemRow: View {
    @Environment(\.editMode) private var editMode
    
    let item: DownloadItem
    @Binding var shareItems: [Any]
    @Binding var selectedItems: Set<URL>
    var importIpaToLibrary: (DownloadItem) -> Void
    var exportToFiles: (DownloadItem) -> Void
    var deleteItem: (DownloadItem) -> Void

    @State private var showingConfirmationDialog = false

    init(
        item: DownloadItem,
        shareItems: Binding<[Any]>,
        selectedItems: Binding<Set<URL>>,
        importIpaToLibrary: @escaping (DownloadItem) -> Void,
        exportToFiles: @escaping (DownloadItem) -> Void,
        deleteItem: @escaping (DownloadItem) -> Void
    ) {
        self.item = item
        self._shareItems = shareItems
        self._selectedItems = selectedItems
        self.importIpaToLibrary = importIpaToLibrary
        self.exportToFiles = exportToFiles
        self.deleteItem = deleteItem
    }
    
    private var _isEditing: Bool {
        editMode?.wrappedValue == .active
    }
    
    private var _isSelected: Bool {
        selectedItems.contains(item.localPath)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Selection circle in edit mode. Only finished downloads are
            // selectable — bulk actions don't apply to in-progress items.
            if _isEditing && item.isFinished {
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
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 31, height: 31)
                        .animation(.smooth, value: item.progress)

                    Image(systemName: item.progress >= 0.75 ? "archivebox" : "square.fill")
                        .foregroundStyle(.tint)
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
        .scaleEffect(_isSelected ? 0.98 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            if _isEditing {
                if item.isFinished {
                    _toggleSelection()
                }
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
            if !_isEditing {
                fileConfirmationDialogButtons()
            }
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
    
    private func _toggleSelection() {
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()
        
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8, blendDuration: 0)) {
            if _isSelected {
                selectedItems.remove(item.localPath)
            } else {
                selectedItems.insert(item.localPath)
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
        
        Button(role: .destructive) {
            deleteItem(item)
        } label: {
            Label(.localized("Delete"), systemImage: "trash")
        }
    }

    @ViewBuilder
    private func swipeActions() -> some View {
        Button(role: .destructive) {
            withAnimation {
                deleteItem(item)
            }
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
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 31, height: 31)
                    .animation(.smooth, value:  download.overallProgress)

                Image(systemName: download.overallProgress >= 0.75 ? "archivebox" : "square.fill")
                    .foregroundStyle(.tint)
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

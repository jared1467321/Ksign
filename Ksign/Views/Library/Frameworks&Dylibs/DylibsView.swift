//
//  DylibsView.swift
//  Ksign
//
//  Created by Nagata Asami on 22/5/25.
//

import SwiftUI
import NimbleExtensions
import NimbleViews
import Zsign

struct DylibsView: View {
    var app: AppInfoPresentable
    @Environment(\.dismiss) private var dismiss
    @AppStorage("Feather.useLastExportLocation") private var _useLastExportLocation: Bool = false
    
    @State private var dylibFiles: [URL] = []
    @State private var selectedDylibs: [URL] = []
    @State private var showDirectoryPicker = false
    @State private var hiddenDylibCount: Int = 0
    @State private var searchText: String = ""
    @State private var _archiveRelativePathByVirtualURL: [String: String] = [:]
    @State private var _archiveExportTemp: URL?
    var body: some View {
        NBNavigationView(app.name ?? .localized("Frameworks & Dylibs"), displayMode: .inline) {
            VStack {
                List(dylibFiles.filter { searchText.isEmpty ? true : $0.lastPathComponent.localizedCaseInsensitiveContains(searchText) }, id: \.absoluteString) { fileURL in
                    Group {
                    DylibRowView(
                        fileURL: fileURL,
                        isSelected: selectedDylibs.contains(fileURL),
                        toggleSelection: {
                            toggleDylibSelection(fileURL)
                        }
                    )
                    }
                    .nbThemeRow()
                }
                .listStyle(.plain)
                .nbThemeCanvas()
                if hiddenDylibCount > 0 {
                    Text(verbatim: .localized("%lld required system dylibs not shown", arguments: hiddenDylibCount))
                        .font(.footnote)
                        .nbThemeForeground(.disabledText)
                }
            }
            .nbThemeOverlay(alignment: .center) {
                if dylibFiles.isEmpty {
                    if #available(iOS 17.0, *) {
                        ContentUnavailableView {
                            Label(.localized("No Frameworks"), systemImage: "doc.text.magnifyingglass")
                                .nbThemeForeground(.heading)
                        } description: {
                            Text(.localized("No frameworks or dylibs found in this app"))
                                .nbThemeForeground(.textSecondary)
                        }
                    } else {
                        VStack(spacing: 15) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.largeTitle)
                                .nbThemeForeground(.textSecondary)
                            
                            Text(.localized("No Frameworks"))
                                .font(.headline)
                            
                            Text(.localized("No frameworks or dylibs found in this app"))
                                .font(.subheadline)
                                .nbThemeForeground(.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(.localized("Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        FRAppIconView(app: app, size: 28)
                        Text(app.name ?? .localized("Frameworks & Dylibs"))
                            .font(.headline)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(.localized("Copy")) {
                        _prepareSelectedDylibsForExport()
                    }
                    .disabled(selectedDylibs.isEmpty)
                }
            }
            .onAppear {
                loadDylibFiles()
            }
            .sheet(isPresented: $showDirectoryPicker) {
                FileExporterRepresentableView(
                    urlsToExport: selectedDylibs,
                    asCopy: true,
                    useLastLocation: _useLastExportLocation,
                    onCompletion: { _ in
                        selectedDylibs.removeAll()
                        if let temp = _archiveExportTemp {
                            try? FileManager.default.removeItem(at: temp)
                            _archiveExportTemp = nil
                        }
                    }
                )
            }
            .searchable(text: $searchText)
        }
    }
    
    private func loadDylibFiles() {
        dylibFiles = []
        hiddenDylibCount = 0
        _archiveRelativePathByVirtualURL.removeAll()

        if let archiveURL = Storage.shared.getArchiveURL(for: app) {
            DispatchQueue.global(qos: .userInitiated).async {
                let inspectRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("FeatherArchiveLibraryDylibInspect_\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: inspectRoot) }

                do {
                    let archivedApp = try ArchiveBackedApp(archiveURL: archiveURL)
                    let metadata = try archivedApp.metadata()
                    var hiddenCount = 0

                    if let executable = metadata.executable, !executable.isEmpty {
                        let executableURL = inspectRoot.appendingPathComponent(executable)
                        if try archivedApp.extract(relativePath: executable, to: executableURL) {
                            let allDylibs = Zsign.listDylibs(appExecutable: executableURL.path).map { $0 as String }
                            let visibleDylibs = allDylibs.filter { $0.hasPrefix("@rpath") || $0.hasPrefix("@executable_path") }
                            hiddenCount = allDylibs.count - visibleDylibs.count
                        }
                    }

                    var relativePaths = archivedApp.list(relativePrefix: "")
                        .filter { $0.lowercased().hasSuffix(".dylib") }
                    relativePaths += archivedApp.list(relativePrefix: "Frameworks")
                        .filter {
                            let lower = $0.lowercased()
                            return lower.hasSuffix(".framework") || lower.hasSuffix(".dylib")
                        }
                        .map { "Frameworks/\($0)" }
                    relativePaths = Array(Set(relativePaths)).sorted {
                        URL(fileURLWithPath: $0).lastPathComponent.localizedCaseInsensitiveCompare(
                            URL(fileURLWithPath: $1).lastPathComponent
                        ) == .orderedAscending
                    }

                    var map: [String: String] = [:]
                    let virtualURLs = relativePaths.map { relative -> URL in
                        let virtual = URL(fileURLWithPath: "/__FeatherArchive__/\(relative)")
                        map[virtual.path] = relative
                        return virtual
                    }

                    DispatchQueue.main.async {
                        dylibFiles = virtualURLs
                        hiddenDylibCount = hiddenCount
                        _archiveRelativePathByVirtualURL = map
                    }
                } catch {
                    print("[ArchiveBacked] Failed to list frameworks/dylibs: \(error)")
                }
            }
            return
        }

        guard let appPath = Storage.shared.getAppDirectory(for: app) else { return }
        let bundle = Bundle(url: appPath)
        let execPath = appPath.appendingPathComponent(bundle?.exec ?? "").relativePath
        let allDylibs = Zsign.listDylibs(appExecutable: execPath).map { $0 as String }
        let visibleDylibs = allDylibs.filter { $0.hasPrefix("@rpath") || $0.hasPrefix("@executable_path") }
        hiddenDylibCount = allDylibs.count - visibleDylibs.count
        
        let fileManager = FileManager.default
        let searchPaths = [
            appPath,
            appPath.appendingPathComponent("Frameworks")
        ]
        
        DispatchQueue.global(qos: .userInitiated).async {
            var collectedFiles: [URL] = []
            for path in searchPaths {
                guard fileManager.fileExists(atPath: path.path) else { continue }
                if let fileURLs = try? fileManager.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) {
                    collectedFiles.append(contentsOf: fileURLs.filter { url in
                        let ext = url.pathExtension.lowercased()
                        return ext == "framework" || ext == "dylib"
                    })
                }
            }
            let sortedFiles = collectedFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }
            DispatchQueue.main.async {
                self.dylibFiles = sortedFiles
                self.hiddenDylibCount = hiddenDylibCount
            }
        }
    }

    private func _prepareSelectedDylibsForExport() {
        guard let archiveURL = Storage.shared.getArchiveURL(for: app) else {
            showDirectoryPicker = true
            return
        }

        let selections = selectedDylibs.compactMap { url -> (URL, String)? in
            guard let relative = _archiveRelativePathByVirtualURL[url.path] else { return nil }
            return (url, relative)
        }
        guard !selections.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("FeatherArchiveDylibExport_\(UUID().uuidString)", isDirectory: true)
            do {
                let archivedApp = try ArchiveBackedApp(archiveURL: archiveURL)
                try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
                var materialized: [URL] = []
                for (_, relative) in selections {
                    let destination = tempRoot.appendingPathComponent(URL(fileURLWithPath: relative).lastPathComponent)
                    if try archivedApp.extractTree(relativePath: relative, to: destination) {
                        materialized.append(destination)
                    }
                }
                DispatchQueue.main.async {
                    _archiveExportTemp = tempRoot
                    selectedDylibs = materialized
                    showDirectoryPicker = !materialized.isEmpty
                }
            } catch {
                try? FileManager.default.removeItem(at: tempRoot)
                DispatchQueue.main.async {
                    UIAlertController.showAlertWithOk(
                        title: .localized("Copy"),
                        message: error.localizedDescription
                    )
                }
            }
        }
    }
    
    private func toggleDylibSelection(_ fileURL: URL) {
        if let index = selectedDylibs.firstIndex(of: fileURL) {
            selectedDylibs.remove(at: index)
        } else {
            selectedDylibs.append(fileURL)
        }
    }
    
}

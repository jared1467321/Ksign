//
//  SourceAppsTableView.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//

import SwiftUI
import NimbleExtensions
import AltSourceKit

// MARK: - Representable
struct SourceAppsTableRepresentableView: UIViewRepresentable {
    @Environment(\.nbThemeInspectorContext) private var inspectorContext
    @ObservedObject private var themes = NBThemeManager.shared
    var sources: [ASRepository]
    @Binding var searchText: String
    @Binding var sortOption: SourceAppsView.SortOption
    @Binding var sortAscending: Bool
    var onSelect: (SourceAppsView.SourceAppRoute) -> Void
    
    func makeUIView(context: Context) -> UITableView {
        let tableView = UITableView(frame: .zero, style: .plain)
        tableView.backgroundColor = .clear
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "AppCell")
        tableView.register(UITableViewHeaderFooterView.self, forHeaderFooterViewReuseIdentifier: "SectionHeader")
        
        if #available(iOS 17, *) {
            tableView.allowsSelection = true
        } else {
            tableView.allowsSelection = false
        }
        
        if
            let firstSource = sources.first,
            sources.count == 1,
            let news = firstSource.news,
            !news.isEmpty
        {
            let header = UIHostingController(rootView: SourceAppsThemeHost(coordinator: context.coordinator) {
                SourceNewsView(news: news)
            })
            header.view.translatesAutoresizingMaskIntoConstraints = true
            header.view.backgroundColor = .clear
            let fixedHeight: CGFloat = 161
            let width = tableView.bounds.width
            header.view.frame = CGRect(origin: .zero, size: CGSize(width: width, height: fixedHeight))

            DispatchQueue.main.async {
                tableView.tableHeaderView = header.view
            }
        }
        
        tableView.alpha = 0
        
        UIView.transition(with: tableView,  duration: 0.5, options: [.transitionCrossDissolve], animations: {
            tableView.alpha = 1
        }, completion: nil)
        
        return tableView
    }
    
    func updateUIView(_ tableView: UITableView, context: Context) {
        if context.coordinator.inspectorContext != inspectorContext {
            let coordinator = context.coordinator
            let snapshot = inspectorContext
            // Update existing hosts, not just newly dequeued rows. Publishing
            // after this representable update avoids a SwiftUI render mutation.
            DispatchQueue.main.async { [weak coordinator] in
                coordinator?.inspectorContext = snapshot
            }
        }
        context.coordinator.uiTableView = tableView
        tableView.backgroundColor = .clear
        tableView.separatorColor = themes.activeColor(for: .separator).uiColor
        tableView.sectionIndexColor = themes.activeColor(for: .accent).uiColor
        tableView.sectionIndexBackgroundColor = .clear
        
        let sourcesChanged = context.coordinator.sources != sources
        let searchChanged = context.coordinator.searchText != searchText
        let sortOptionChanged = context.coordinator.sortOption != sortOption
        let sortDirectionChanged = context.coordinator.sortAscending != sortAscending
        
        context.coordinator.sources = sources
        context.coordinator.searchText = searchText
        context.coordinator.sortOption = sortOption
        context.coordinator.sortAscending = sortAscending
        
        if sourcesChanged || searchChanged || sortOptionChanged || sortDirectionChanged {
            context.coordinator.invalidateCache()
        }
    }
    
    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(
            sources: sources,
            searchText: searchText,
            sortOption: sortOption,
            sortAscending: sortAscending,
            onSelect: onSelect
        )
        coordinator.inspectorContext = inspectorContext
        return coordinator
    }
}

// MARK: - Representable Extension: Coordinator
extension SourceAppsTableRepresentableView { class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate, ObservableObject {
    @Published var inspectorContext = NBThemeInspectorContext()
    var sources: [ASRepository]
    var searchText: String
    var sortOption: SourceAppsView.SortOption
    var sortAscending: Bool
    let onSelect: (SourceAppsView.SourceAppRoute) -> Void
    
    private var _groupedAppsByNameFirstLetter: [String: [(source: ASRepository, app: ASRepository.App)]] = [:]
    private var _groupedAppsByDate: [String: [(source: ASRepository, app: ASRepository.App)]] = [:]
    private var _sortedSectionTitles: [String] = []
    
    private var _cachedSortedApps: [(source: ASRepository, app: ASRepository.App)] = []
    weak var uiTableView: UITableView?
    
    private var _displayedSortOption: SourceAppsView.SortOption = .default
    private var _generation = UUID()
    private static let catalogQueue = DispatchQueue(label: "Asign.source-catalog", qos: .userInitiated)
    private lazy var _projection = LatestValueDelivery<SourceAppsProjection.Request>(
        interval: 0.1, queue: Self.catalogQueue
    ) { [weak self] request in
        let snapshot = SourceAppsProjection.build(request)
        DispatchQueue.main.async { [weak self] in
            guard let self, self._generation == request.generation else { return }
            self._cachedSortedApps = snapshot.apps
            self._groupedAppsByNameFirstLetter = request.sortOption == .name ? snapshot.groups : [:]
            self._groupedAppsByDate = request.sortOption == .date ? snapshot.groups : [:]
            self._sortedSectionTitles = snapshot.titles
            self._displayedSortOption = request.sortOption
            self.uiTableView?.reloadData()
        }
    }

    private var _sortedApps: [SourceAppsProjection.Entry] { _cachedSortedApps }

    init(
        sources: [ASRepository],
        searchText: String,
        sortOption: SourceAppsView.SortOption,
        sortAscending: Bool,
        onSelect: @escaping (SourceAppsView.SourceAppRoute) -> Void
    ) {
        self.sources = sources
        self.searchText = searchText
        self.sortOption = sortOption
        self.sortAscending = sortAscending
        self.onSelect = onSelect
        super.init()
        
        invalidateCache()
    }

    func invalidateCache() {
        _generation = UUID()
        _projection.submit(.init(sources: sources, searchText: searchText, sortOption: sortOption,
                                 ascending: sortAscending, generation: _generation))
    }

    deinit { _projection.cancel() }

    // MARK: TableView
    
    func numberOfSections(in tableView: UITableView) -> Int {
        switch _displayedSortOption {
        case .default: 1
        case .name, .date: _sortedSectionTitles.count
        }
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch _displayedSortOption {
        case .default: _sortedApps.count
        case .name: _groupedAppsByNameFirstLetter[_sortedSectionTitles[section]]?.count ?? 0
        case .date: _groupedAppsByDate[_sortedSectionTitles[section]]?.count ?? 0
        }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "AppCell", for: indexPath)
        let entry: (source: ASRepository, app: ASRepository.App)
        switch _displayedSortOption {
        case .default: entry = _sortedApps[indexPath.row]
        case .name: entry = _groupedAppsByNameFirstLetter[_sortedSectionTitles[indexPath.section]]?[indexPath.row] ?? _sortedApps[indexPath.row]
        case .date: entry = _groupedAppsByDate[_sortedSectionTitles[indexPath.section]]?[indexPath.row] ?? _sortedApps[indexPath.row]
        }

        cell.backgroundColor = .clear
        cell.contentConfiguration = UIHostingConfiguration {
            SourceAppsThemeHost(coordinator: self) {
                SourceAppsCellView(source: entry.source, app: entry.app)
                    .nbThemeForeground(.text)
                    .padding(12)
                    .nbThemeBackground(.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if #available(iOS 17, *) {
            tableView.deselectRow(at: indexPath, animated: true)
            
            let entry: (source: ASRepository, app: ASRepository.App)
            switch _displayedSortOption {
            case .default: entry = _sortedApps[indexPath.row]
            case .name: entry = _groupedAppsByNameFirstLetter[_sortedSectionTitles[indexPath.section]]?[indexPath.row] ?? _sortedApps[indexPath.row]
            case .date: entry = _groupedAppsByDate[_sortedSectionTitles[indexPath.section]]?[indexPath.row] ?? _sortedApps[indexPath.row]
            }
            
            onSelect(SourceAppsView.SourceAppRoute(source: entry.source, app: entry.app))
        }
    }
    
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let headerView = tableView.dequeueReusableHeaderFooterView(withIdentifier: "SectionHeader")
        let title: String
        
        switch _displayedSortOption {
        case .default: title = .localized("%lld Apps", arguments: _sortedApps.count)
        case .name, .date: title = _sortedSectionTitles[section]
        }
        
        headerView?.contentConfiguration = UIHostingConfiguration {
            SourceAppsThemeHost(coordinator: self) {
            HStack {
                Text(verbatim: title)
                    .nbThemeForeground(.heading)
                Spacer()
            }
            .font(.headline)
            .padding(.vertical, 2)
            }
        }
        
        headerView?.backgroundConfiguration = UIBackgroundConfiguration.clear()
        return headerView
    }
    
    func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        _displayedSortOption == .name ? _sortedSectionTitles : nil
    }
    
    func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
        _sortedSectionTitles.firstIndex(of: title) ?? 0
    }
    
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let entry: (source: ASRepository, app: ASRepository.App)
        switch _displayedSortOption {
        case .default: entry = _sortedApps[indexPath.row]
        case .name: entry = _groupedAppsByNameFirstLetter[_sortedSectionTitles[indexPath.section]]?[indexPath.row] ?? _sortedApps[indexPath.row]
        case .date: entry = _groupedAppsByDate[_sortedSectionTitles[indexPath.section]]?[indexPath.row] ?? _sortedApps[indexPath.row]
        }
        
        return UIContextMenuConfiguration(
            identifier: nil,
            previewProvider: nil
        ) { _ in
            let versionsMenu = UIMenu(
                title: .localized("Copy Download URLs"),
                image: UIImage(systemName: "list.bullet"),
                children: self._contextActions(for: entry.app, with: { version in
                    UIPasteboard.general.string = version?.absoluteString
                }, image: UIImage(systemName: "doc.on.clipboard"))
            )
            
            let downloadsMenu = UIMenu(
                title: .localized("Previous Versions"),
                image: UIImage(systemName: "square.and.arrow.down.on.square"),
                children: self._contextActions(for: entry.app, with: { version in
                    if let url = version {
                        _ = DownloadManager.shared.startDownload(
                            from: url,
                            id: entry.app.currentUniqueId
                        )
                    }
                }, image: UIImage(systemName: "arrow.down"))
            )
            
            return UIMenu(children: [downloadsMenu, versionsMenu])
        }
    }
    
    // MARK: Actions
    
    private func _contextActions(
        for app: ASRepository.App,
        with action: @escaping (URL?) -> Void,
        image: UIImage?
    ) -> [UIAction] {
        if let versions = app.versions, !versions.isEmpty {
            return versions.map { version in
                UIAction(
                    title: version.version,
                    image: image
                ) { _ in
                    action(version.downloadURL)
                }
            }
        } else {
            return [
                UIAction(
                    title: app.currentVersion ?? "",
                    image: image
                ) { _ in
                    action(app.currentDownloadUrl)
                }
            ]
        }
    }
}}


/// UIHostingConfiguration does not inherit the representable's environment.
/// Keep the same live ownership context for existing and recycled cell hosts.
private struct SourceAppsThemeHost<Content: View>: View {
    @ObservedObject var coordinator: SourceAppsTableRepresentableView.Coordinator
    let content: Content
    init(coordinator: SourceAppsTableRepresentableView.Coordinator, @ViewBuilder content: () -> Content) {
        self.coordinator = coordinator
        self.content = content()
    }
    var body: some View {
        content.environment(\.nbThemeInspectorContext, coordinator.inspectorContext)
    }
}

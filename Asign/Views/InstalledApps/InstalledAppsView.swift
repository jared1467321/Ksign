import SwiftUI
import IDeviceSwift
import NimbleViews
import NimbleExtensions

struct InstalledAppsView: View {
    @ObservedObject var model: InstalledAppsModel
    @ObservedObject private var reconnect = VPNReconnectCoordinator.shared
    @ObservedObject private var blacklist = UninstallBlacklist.shared
    @State private var searchText = ""
    @State private var isEditing = false
    @State private var selectedIDs: Set<String> = []
    @State private var removal: DeviceUninstallSelection?
    @State private var showsBlacklist = false

    private var unprotectedApps: [IDeviceInstalledApp] {
        model.apps.filter { !blacklist.contains($0.id) }
    }

    private var visibleApps: [IDeviceInstalledApp] {
        unprotectedApps.filter {
            searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.id.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var selectableVisibleIDs: Set<String> {
        Set(visibleApps.filter { restriction($0) == nil }.map(\.id))
    }

    private var selectedApps: [IDeviceInstalledApp] {
        unprotectedApps.filter { selectedIDs.contains($0.id) && restriction($0) == nil }
    }

    var body: some View {
        NBListAdaptable(rendersAurora: false, adaptsContainerText: false) {
            if reconnect.pendingShortcutName != nil {
                NBSection("Reconnect VPN") {
                    VPNReconnectBannerView()
                }
            }
            NBSection("On This Device", secondary: model.hasLoaded ? unprotectedApps.count.description : nil) {
                Text("Only verified apps installed through Asign appear here. Their IPA files don't need to be kept in your library.")
                    .font(.callout).nbThemeForeground(.textSecondary)
                Text("Apps installed before tracking was added must be installed through Asign again to appear here.")
                    .font(.caption).nbThemeForeground(.textSecondary)
                Text("Use Blacklist to protect apps from accidental uninstallation. You can also swipe an app or use its menu to add it.")
                    .font(.caption).nbThemeForeground(.textSecondary)
                Button {
                    showsBlacklist = true
                } label: {
                    Label("Blacklist (\(blacklist.entries.count))", systemImage: "shield.lefthalf.filled")
                }
                if model.hasLoaded {
                    Text(model.apps.contains(where: { $0.registrationDate != nil })
                         ? "Newest first. Apps without an available date are listed last."
                         : "iOS did not provide installation dates. Apps are listed by name.")
                        .font(.caption).nbThemeForeground(.textSecondary)
                }
                if model.isLoading {
                    ProgressView("Loading installed apps…").nbThemeTint(.accent)
                    Button("Cancel Loading", role: .cancel) { model.cancelLoading() }
                } else if !model.hasLoaded {
                    Text("Uses your iDevice connection. Select Built-in Connection or Manual Setup in Settings → Installation.")
                        .font(.callout).nbThemeForeground(.textSecondary)
                    Button("Load Installed Apps") { model.load() }
                }
                if let error = model.error {
                    Text(error).font(.callout).nbThemeForeground(.danger)
                }
            }
            if !visibleApps.isEmpty {
                NBSection("Installed Apps", secondary: visibleApps.count.description) {
                    ForEach(visibleApps) { app in
                        InstalledAppRow(app: app, restriction: restriction(app), isEditing: isEditing,
                            isSelected: selectedIDs.contains(app.id),
                            onToggle: { toggle(app) },
                            onUninstall: { presentRemoval([app]) },
                            onBlacklist: { blacklist.add(app) })
                            .allowsHitTesting(!model.isLoading)
                    }
                }
            } else if model.hasLoaded, !model.isLoading {
                NBSection("Installed Apps") {
                    Text(searchText.isEmpty
                         ? (model.apps.isEmpty ? "No verified Asign-installed apps are on this device." : "All loaded apps are blacklisted. Open Blacklist to manage them.")
                         : "No apps match your search.")
                        .nbThemeForeground(.textSecondary)
                }
            }
            DeviceConnectionSetupView(failureInstructions: "Once connected, tap Refresh in Installed Apps.")
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
        .refreshable { await refresh() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button(isEditing ? "Done" : "Edit") {
                    isEditing.toggle()
                    if !isEditing { selectedIDs.removeAll() }
                }
                .disabled(!model.hasLoaded || model.isLoading)
                if isEditing {
                    Button {
                        let visible = selectableVisibleIDs
                        if visible.isSubset(of: selectedIDs) { selectedIDs.subtract(visible) }
                        else { selectedIDs.formUnion(visible) }
                    } label: {
                        SelectionCheckIcon(isSelected: !selectableVisibleIDs.isEmpty && selectableVisibleIDs.isSubset(of: selectedIDs))
                    }
                    .accessibilityLabel("Select or deselect all visible apps")
                    .disabled(selectableVisibleIDs.isEmpty || model.isLoading)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isEditing {
                    Button(role: .destructive) {
                        presentRemoval(selectedApps)
                    } label: {
                        Label("Uninstall \(selectedApps.count)", systemImage: "minus.circle")
                    }
                    .disabled(selectedApps.isEmpty || model.isLoading)
                }
                Button {
                    selectedIDs.removeAll()
                    model.load()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
            }
        }
        .sheet(item: $removal) { selection in
            UninstallAppsView(selection: selection) { bundleIdentifier in
                model.remove(bundleIdentifier)
                selectedIDs.remove(bundleIdentifier)
            }
        }
        .sheet(isPresented: $showsBlacklist) {
            UninstallBlacklistView(model: model)
        }
        .onAppear {
            blacklist.reload()
            selectedIDs.subtract(blacklist.entries.keys)
        }
        .onChange(of: blacklist.entries) { entries in
            selectedIDs.subtract(entries.keys)
        }
        .onChange(of: model.apps.map(\.id)) { ids in
            selectedIDs.formIntersection(ids)
        }
    }

    private func presentRemoval(_ apps: [IDeviceInstalledApp]) {
        let eligible = apps.filter { !blacklist.contains($0.id) && restriction($0) == nil }
        guard !eligible.isEmpty else { return }
        removal = DeviceUninstallSelection(apps: eligible)
    }

    private func refresh() async {
        selectedIDs.removeAll()
        model.load()
        // Let the model own the task across tab changes; keep pull-to-refresh
        // active until the native clients and connection preparation finish.
        while model.isLoading {
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return }
        }
    }

    private func restriction(_ app: IDeviceInstalledApp) -> String? {
        app.removalRestriction(hostBundleIdentifier: Bundle.main.bundleIdentifier)
    }

    private func toggle(_ app: IDeviceInstalledApp) {
        guard !model.isLoading, !blacklist.contains(app.id), restriction(app) == nil else { return }
        if selectedIDs.contains(app.id) { selectedIDs.remove(app.id) }
        else { selectedIDs.insert(app.id) }
    }
}

private struct InstalledAppRow: View {
    let app: IDeviceInstalledApp
    let restriction: String?
    let isEditing: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    let onUninstall: () -> Void
    let onBlacklist: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2).nbThemeForeground(restriction == nil ? .accent : .textSecondary)
                    .nbThemeOpacity(restriction == nil ? 1 : 0.3)
            }
            Image(systemName: "app.fill")
                .font(.system(size: 36)).nbThemeForeground(.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).nbThemeForeground(.heading)
                Text(app.id).font(.caption).nbThemeForeground(.textSecondary)
                if let version = app.version {
                    Text(version).font(.caption).nbThemeForeground(.textSecondary)
                }
                if let date = app.registrationDate {
                    Text("Installed or updated \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).nbThemeForeground(.textSecondary)
                } else {
                    Text("Install date unavailable").font(.caption).nbThemeForeground(.textSecondary)
                }
                if let restriction {
                    Text(restriction).font(.caption).nbThemeForeground(.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .nbThemeTextRow()
        .contentShape(Rectangle())
        .onTapGesture {
            if isEditing { onToggle() }
            else if restriction == nil { onUninstall() }
        }
        .contextMenu {
            Button("Add to Blacklist", systemImage: "plus.shield", action: onBlacklist)
            if !isEditing, restriction == nil {
                Button("Uninstall from Device…", systemImage: "minus.circle", role: .destructive, action: onUninstall)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(action: onBlacklist) {
                Label("Blacklist", systemImage: "plus.shield")
            }
        }
    }
}

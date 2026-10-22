import SwiftUI
import IDeviceSwift
import NimbleViews
import NimbleExtensions

struct InstalledAppsView: View {
    @StateObject private var model = InstalledAppsModel()
    @State private var searchText = ""
    @State private var isEditing = false
    @State private var selectedIDs: Set<String> = []
    @State private var removal: DeviceUninstallSelection?

    private var visibleApps: [IDeviceInstalledApp] {
        model.apps.filter {
            searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.id.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var selectableVisibleIDs: Set<String> {
        Set(visibleApps.filter { restriction($0) == nil }.map(\.id))
    }

    var body: some View {
        NBNavigationView("Installed Apps", adaptsContainerText: false) {
            NBListAdaptable(rendersAurora: false, adaptsContainerText: false) {
                NBSection("On This Device", secondary: model.hasLoaded ? model.apps.count.description : nil) {
                    Text("Apps reported by iOS, including apps that aren't saved in Ksign's library.")
                        .font(.callout).nbThemeForeground(.textSecondary)
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
                                onUninstall: { removal = DeviceUninstallSelection(apps: [app]) })
                                .allowsHitTesting(!model.isLoading)
                        }
                    }
                } else if model.hasLoaded, !model.isLoading {
                    NBSection("Installed Apps") {
                        Text(searchText.isEmpty ? "No user apps were reported by iOS." : "No apps match your search.")
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
                            removal = DeviceUninstallSelection(apps: model.apps.filter { selectedIDs.contains($0.id) })
                        } label: {
                            Label("Uninstall \(selectedIDs.count)", systemImage: "minus.circle")
                        }
                        .disabled(selectedIDs.isEmpty || model.isLoading)
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
        }
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
        guard !model.isLoading, restriction(app) == nil else { return }
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
            if !isEditing, restriction == nil {
                Button("Uninstall from Device…", systemImage: "minus.circle", role: .destructive, action: onUninstall)
            }
        }
    }
}

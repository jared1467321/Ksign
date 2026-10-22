import SwiftUI
import NimbleViews
import NimbleExtensions

@MainActor
private final class UninstallAppsModel: ObservableObject {
    let apps: [DeviceUninstallInput]
    @Published private(set) var statuses: [String: String] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var hasStarted = false
    @Published private(set) var stopRequested = false
    @Published private(set) var notice: String?

    init(apps: [DeviceUninstallInput]) { self.apps = apps }

    func stop() { stopRequested = true }

    func start() {
        guard !hasStarted, !apps.isEmpty else { return }
        guard !InstallSession.shared.hasWorkInProgress, InstallSession.shared.waitingCount == 0 else {
            notice = "Finish or cancel the installation queue before uninstalling apps."
            return
        }
        hasStarted = true
        isRunning = true
        notice = nil
        Task {
            let manager = DeviceInstallationManager.shared
            let workflow = UUID()
            manager.clearSetupFailure()
            manager.retainWorkflow(workflow)
            let background = BackgroundTaskManager.shared
            background.claim(.uninstalling)
            var completed = 0
            var succeeded = true
            // Keep both the model and connection alive until the current native
            // command returns, including when Stop is requested.
            defer {
                manager.releaseWorkflow(workflow)
                background.release(.uninstalling, success: succeeded && !stopRequested)
                isRunning = false
            }
            for app in apps {
                guard !stopRequested else { break }
                statuses[app.id] = "Checking signed app…"
                background.report(.uninstalling, completed: completed, total: apps.count,
                                  fraction: nil, detail: "Checking signed app", currentItem: app.name)
                do {
                    let request = try await Task.detached(priority: .userInitiated) { try app.request() }.value
                    guard !stopRequested else { statuses[app.id] = "Not started"; break }
                    statuses[app.id] = "Uninstalling…"
                    background.report(.uninstalling, detail: "Uninstalling \(app.name)")
                    let removed = try await manager.uninstall(request)
                    statuses[app.id] = removed ? "Uninstalled" : "Already uninstalled"
                } catch {
                    succeeded = false
                    statuses[app.id] = error.localizedDescription
                }
                completed += 1
                background.report(.uninstalling, completed: completed, total: apps.count)
            }
        }
    }
}

struct UninstallAppsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: UninstallAppsModel
    @State private var confirmsRemoval = false

    init(selection: DeviceUninstallSelection) {
        _model = StateObject(wrappedValue: UninstallAppsModel(apps: selection.apps))
    }

    var body: some View {
        NBNavigationView("Uninstall Apps", adaptsContainerText: false) {
            NBListAdaptable(rendersAurora: false, adaptsContainerText: false) {
                NBSection("Remove from Device") {
                    Text("Uninstalling deletes the selected apps and their data from this device. Your signed files stay in Ksign.")
                        .nbThemeForeground(.text)
                    Text("Uses your iDevice connection, including for apps installed with Server. iOS may remove apps without another Delete prompt.")
                        .nbThemeForeground(.textSecondary)
                    if let notice = model.notice {
                        Text(notice).nbThemeForeground(.textSecondary)
                    }
                }
                NBSection("Selected Apps", secondary: model.apps.count.description) {
                    ForEach(model.apps) { app in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).nbThemeForeground(.heading)
                            Text(app.id).font(.caption).nbThemeForeground(.textSecondary)
                            if let status = model.statuses[app.id] {
                                Text(status).font(.callout).nbThemeForeground(.textSecondary)
                            } else if model.hasStarted, !model.isRunning {
                                Text("Not started").font(.callout).nbThemeForeground(.textSecondary)
                            }
                        }
                    }
                }
                if model.isRunning {
                    NBSection("Progress") {
                        ProgressView(model.stopRequested ? "Finishing current app…" : "Removing apps…")
                            .nbThemeTint(.accent)
                        Button("Stop After Current App") { model.stop() }
                            .disabled(model.stopRequested)
                    }
                } else if !model.hasStarted {
                    NBSection("Uninstall") {
                        Button(model.apps.count == 1 ? "Uninstall App…" : "Uninstall \(model.apps.count) Apps…", role: .destructive) {
                            confirmsRemoval = true
                        }
                        .disabled(model.apps.isEmpty)
                    }
                }
                DeviceConnectionSetupView(failureInstructions: "Once connected, close this screen and choose Uninstall from Device again.")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model.hasStarted ? "Done" : "Cancel") { dismiss() }
                        .disabled(model.isRunning)
                }
            }
            .alert("Uninstall selected apps?", isPresented: $confirmsRemoval) {
                Button("Uninstall", role: .destructive) { model.start() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes the selected apps and their data from this device. Only installed copies matching the selected signed apps will be removed.")
            }
        }
        .interactiveDismissDisabled(model.isRunning)
    }
}

import Combine
import Foundation
import IDeviceSwift

@MainActor
final class InstalledAppsModel: ObservableObject {
    @Published private(set) var apps: [IDeviceInstalledApp] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var error: String?
    @Published private(set) var isUninstalling = false
    @Published private(set) var uninstallStatuses: [String: String] = [:]
    @Published private(set) var uninstallCompleted = 0
    @Published private(set) var uninstallTotal = 0
    @Published private(set) var uninstallCurrentAppName: String?
    @Published private(set) var uninstallActiveCount = 0
    @Published private(set) var uninstallStopRequested = false
    @Published private(set) var uninstallSummary: String?
    private var loadTask: Task<Void, Never>?
    private var uninstallBatch: IDeviceUninstallBatch?
    private var uninstallActiveIDs: Set<String> = []
    private var uninstallFinishedIDs: Set<String> = []
    private var uninstallRemovedCount = 0

    func load() {
        guard !isLoading, !isUninstalling else { return }
        guard !InstallSession.shared.hasWorkInProgress, InstallSession.shared.waitingCount == 0 else {
            error = "Finish or cancel the installation queue before refreshing Installed Apps."
            return
        }
        isLoading = true
        error = nil
        loadTask = Task {
            let manager = DeviceInstallationManager.shared
            let workflow = UUID()
            manager.clearSetupFailure()
            manager.retainWorkflow(workflow, requiresVPNChoice: true)
            BackgroundTaskManager.shared.claim(.installedApps)
            var succeeded = false
            defer {
                manager.releaseWorkflow(workflow)
                BackgroundTaskManager.shared.release(.installedApps, success: succeeded)
                isLoading = false
                loadTask = nil
            }
            do {
                let observed = try await Task.detached(priority: .utility) {
                    try IDeviceManagedInstallRegistry.shared.snapshot()
                }.value
                let registry = IDeviceManagedInstallRegistry.shared
                let installed = try await manager.installedApps()
                try Task.checkCancellation()
                let dated = try await Task.detached(priority: .userInitiated) {
                    let dated = installed.map { app in
                        var app = app
                        app.registrationDate = IDeviceInstalledAppDates.registrationDate(for: app.id)
                        return app
                    }
                    return try registry.reconcile(dated, observed: observed,
                        hostBundleIdentifier: Bundle.main.bundleIdentifier).sorted(by: IDeviceInstalledApp.newestFirst)
                }.value
                try Task.checkCancellation()
                apps = dated
                uninstallStatuses = [:]
                uninstallSummary = nil
                hasLoaded = true
                succeeded = true
            } catch is CancellationError {
                self.error = "Loading was cancelled. Tap Load Apps to try again."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func cancelLoading() { loadTask?.cancel() }

    @discardableResult
    func uninstall(_ apps: [IDeviceInstalledApp]) -> Bool {
        guard !isLoading, !isUninstalling else { return false }
        guard !InstallSession.shared.hasWorkInProgress, InstallSession.shared.waitingCount == 0 else {
            error = "Finish or cancel the installation queue before uninstalling apps."
            return false
        }
        let blacklist = UninstallBlacklist.shared
        blacklist.reload()
        let eligible = DeviceUninstallSelection(apps: apps.filter {
            !blacklist.contains($0.id) &&
                $0.removalRestriction(hostBundleIdentifier: Bundle.main.bundleIdentifier) == nil
        }).apps
        guard !eligible.isEmpty else { return false }

        isUninstalling = true
        uninstallStopRequested = false
        uninstallCompleted = 0
        uninstallTotal = eligible.count
        uninstallCurrentAppName = nil
        uninstallActiveCount = 0
        uninstallActiveIDs = []
        uninstallFinishedIDs = []
        uninstallRemovedCount = 0
        uninstallStatuses = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, "Waiting to uninstall…") })
        uninstallSummary = nil
        error = nil
        let batch = IDeviceUninstallBatch(apps: eligible)
        uninstallBatch = batch

        // The library owns this model, so a tab change never detaches the batch
        // or loses progress. Retain the connection until all active apps finish.
        Task {
            let manager = DeviceInstallationManager.shared
            let workflow = UUID()
            manager.clearSetupFailure()
            manager.retainWorkflow(workflow)
            let background = BackgroundTaskManager.shared
            background.claim(.uninstalling)
            defer {
                // Completions can arrive out of selection order. Drain the
                // recorded results before ignoring late progress deliveries.
                for (id, result) in batch.results {
                    applyUninstallEvent(.finished(id, result), batch: batch)
                }
                for app in eligible where !uninstallFinishedIDs.contains(app.id) {
                    uninstallStatuses[app.id] = "Not started"
                }
                uninstallSummary = (uninstallStopRequested ? "Stopped. " : "") +
                    "Uninstalled \(uninstallRemovedCount) of \(eligible.count) apps."
                uninstallCurrentAppName = nil
                uninstallActiveCount = 0
                uninstallActiveIDs = []
                uninstallBatch = nil
                manager.releaseWorkflow(workflow)
                background.release(.uninstalling, success: uninstallRemovedCount == eligible.count && !uninstallStopRequested)
                isUninstalling = false
            }
            do {
                try await manager.uninstall(batch) { [weak self] event in
                    Task { @MainActor in self?.applyUninstallEvent(event, batch: batch) }
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
        return true
    }

    func stopUninstalling() {
        guard isUninstalling else { return }
        uninstallStopRequested = true
        uninstallBatch?.stop()
    }

    private func applyUninstallEvent(_ event: IDeviceUninstallEvent, batch: IDeviceUninstallBatch) {
        guard uninstallBatch === batch else { return }
        switch event {
        case .started(let id):
            guard !uninstallFinishedIDs.contains(id) else { return }
            uninstallActiveIDs.insert(id)
            uninstallStatuses[id] = "Uninstalling…"
        case .finished(let id, let result):
            guard uninstallFinishedIDs.insert(id).inserted else { return }
            uninstallActiveIDs.remove(id)
            switch result {
            case .success(let removed):
                uninstallStatuses[id] = removed ? "Uninstalled" : "Already uninstalled"
                remove(id)
                uninstallRemovedCount += 1
            case .failure(let error):
                uninstallStatuses[id] = error.localizedDescription
            }
            uninstallCompleted = uninstallFinishedIDs.count
        }
        uninstallActiveCount = uninstallActiveIDs.count
        uninstallCurrentAppName = uninstallActiveIDs.count == 1
            ? apps.first(where: { uninstallActiveIDs.contains($0.id) })?.name : nil
        let detail = uninstallActiveCount == 1
            ? "Uninstalling \(uninstallCurrentAppName ?? "app")" : "Uninstalling \(uninstallActiveCount) apps"
        BackgroundTaskManager.shared.report(.uninstalling, completed: uninstallCompleted, total: uninstallTotal,
                                             fraction: nil, detail: detail, currentItem: uninstallCurrentAppName)
    }

    private func remove(_ bundleIdentifier: String) {
        apps.removeAll { $0.id == bundleIdentifier }
    }
}

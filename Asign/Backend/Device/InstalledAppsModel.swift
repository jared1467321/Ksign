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
    @Published private(set) var uninstallStopRequested = false
    @Published private(set) var uninstallSummary: String?
    private var loadTask: Task<Void, Never>?

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
                let registry = IDeviceManagedInstallRegistry.shared
                let observed = try registry.snapshot()
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
        uninstallStatuses = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, "Waiting to uninstall…") })
        uninstallSummary = nil
        error = nil

        // The library owns this model, so a tab change never detaches the batch
        // or loses its progress. Keep the connection until the current app ends.
        Task {
            let manager = DeviceInstallationManager.shared
            let workflow = UUID()
            manager.clearSetupFailure()
            manager.retainWorkflow(workflow)
            let background = BackgroundTaskManager.shared
            background.claim(.uninstalling)
            var removedCount = 0
            var succeeded = true
            defer {
                for app in eligible.dropFirst(uninstallCompleted) {
                    uninstallStatuses[app.id] = "Not started"
                }
                uninstallSummary = (uninstallStopRequested ? "Stopped. " : "") +
                    "Uninstalled \(removedCount) of \(eligible.count) apps."
                uninstallCurrentAppName = nil
                manager.releaseWorkflow(workflow)
                background.release(.uninstalling, success: succeeded && !uninstallStopRequested)
                isUninstalling = false
            }
            for app in eligible {
                guard !uninstallStopRequested else { break }
                uninstallCurrentAppName = app.name
                uninstallStatuses[app.id] = "Checking installed app…"
                background.report(.uninstalling, completed: uninstallCompleted, total: eligible.count,
                                  fraction: nil, detail: "Checking installed app", currentItem: app.name)
                do {
                    let request = try IDeviceUninstallRequest(installedApp: app)
                    uninstallStatuses[app.id] = "Uninstalling…"
                    background.report(.uninstalling, detail: "Uninstalling \(app.name)")
                    let removed = try await manager.uninstall(request)
                    uninstallStatuses[app.id] = removed ? "Uninstalled" : "Already uninstalled"
                    remove(app.id)
                    removedCount += 1
                } catch {
                    succeeded = false
                    uninstallStatuses[app.id] = error.localizedDescription
                }
                uninstallCompleted += 1
                background.report(.uninstalling, completed: uninstallCompleted, total: eligible.count)
            }
        }
        return true
    }

    func stopUninstalling() {
        guard isUninstalling else { return }
        uninstallStopRequested = true
    }

    private func remove(_ bundleIdentifier: String) {
        apps.removeAll { $0.id == bundleIdentifier }
    }
}

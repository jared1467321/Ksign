import Combine
import Foundation
import IDeviceSwift

@MainActor
final class InstalledAppsModel: ObservableObject {
    @Published private(set) var apps: [IDeviceInstalledApp] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var error: String?
    private var loadTask: Task<Void, Never>?

    func load() {
        guard !isLoading else { return }
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

    func remove(_ bundleIdentifier: String) {
        apps.removeAll { $0.id == bundleIdentifier }
    }
}

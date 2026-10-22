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
            manager.retainWorkflow(workflow)
            BackgroundTaskManager.shared.claim(.installedApps)
            var succeeded = false
            defer {
                manager.releaseWorkflow(workflow)
                BackgroundTaskManager.shared.release(.installedApps, success: succeeded)
                isLoading = false
                loadTask = nil
            }
            do {
                let installed = try await manager.installedApps()
                try Task.checkCancellation()
                apps = installed.sorted {
                    let order = $0.name.localizedStandardCompare($1.name)
                    return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
                }
                hasLoaded = true
                succeeded = true
            } catch is CancellationError {
                self.error = "Loading was cancelled. Tap Refresh to try again."
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

import Foundation
import IDeviceSwift

struct DeviceUninstallSelection: Identifiable {
    let id = UUID()
    let apps: [DeviceUninstallInput]

    @MainActor
    init(apps: [AppInfoPresentable]) {
        var seen: Set<String> = []
        self.apps = apps.compactMap { app in
            guard app.isSigned, let identifier = app.identifier,
                  !identifier.isEmpty, seen.insert(identifier).inserted else { return nil }
            return DeviceUninstallInput(
                id: identifier, name: app.name ?? identifier,
                archiveURL: Storage.shared.getArchiveURL(for: app),
                appDirectory: Storage.shared.getAppDirectory(for: app))
        }
    }
}

/// Snapshot Core Data on the main actor; inspect files on a worker.
struct DeviceUninstallInput: Identifiable, Sendable {
    let id: String
    let name: String
    let archiveURL: URL?
    let appDirectory: URL?

    func request() throws -> IDeviceUninstallRequest {
        guard id != Bundle.main.bundleIdentifier else {
            throw DeviceSetupError("Ksign cannot uninstall itself.")
        }
        if let archiveURL {
            let archive = try ArchiveBackedApp(archiveURL: archiveURL)
            guard let data = try archive.data(relativePath: "Info.plist", maximumBytes: 16 * 1024 * 1024) else {
                throw ArchiveBackedAppError.infoPlistMissing
            }
            let executable = try executableName(in: data)
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("UninstallIdentity-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let binary = scratch.appendingPathComponent("Executable")
            guard try archive.extract(relativePath: executable, to: binary) else {
                throw DeviceSetupError("The signed app's executable is missing. Sign it again before uninstalling from Ksign.")
            }
            return try IDeviceUninstallRequest(bundleIdentifier: id, executableURL: binary)
        }
        guard let appDirectory else {
            throw DeviceSetupError("The signed app's files are missing. Sign it again before uninstalling from Ksign.")
        }
        let executable = try executableName(in: Data(contentsOf: appDirectory.appendingPathComponent("Info.plist")))
        return try IDeviceUninstallRequest(bundleIdentifier: id,
            executableURL: appDirectory.appendingPathComponent(executable))
    }

    private func executableName(in data: Data) throws -> String {
        guard let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == id,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable != ".", executable != "..",
              !executable.contains("/"), !executable.contains("\\"), !executable.contains("\0") else {
            throw DeviceSetupError("The signed app's metadata could not be verified. Sign it again before uninstalling from Ksign.")
        }
        return executable
    }
}

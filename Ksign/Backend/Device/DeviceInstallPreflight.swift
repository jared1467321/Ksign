import Foundation
import IDeviceSwift

enum DeviceInstallPreflight {
    static func inspect(appDirectory: URL) throws -> IDeviceInstallPreflight? {
        let data = try Data(contentsOf: appDirectory.appendingPathComponent("Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { throw ArchiveBackedAppError.invalidInfoPlist }
        try IDeviceInstallPreflight.checkPlatform(info)
        guard let id = info["CFBundleIdentifier"] as? String, !id.isEmpty,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"), !executable.contains("\\"),
              executable != ".", executable != ".." else { return nil }
        return IDeviceInstallPreflight(bundleIdentifier: id) { installed in
            try IDeviceInstallPreflight.checkSigningIdentity(
                executableURL: appDirectory.appendingPathComponent(executable), installed: installed)
        }
    }

    /// Inspect the final signed IPA, not its source-library metadata. No device
    /// connection is needed for platform checks, and no app tree is extracted.
    static func inspect(_ packageURL: URL) throws -> IDeviceInstallPreflight? {
        let archive = try ArchiveBackedApp(archiveURL: packageURL)
        guard let data = try archive.data(relativePath: "Info.plist", maximumBytes: 16 * 1024 * 1024),
              let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { throw ArchiveBackedAppError.invalidInfoPlist }
        try IDeviceInstallPreflight.checkPlatform(info)
        guard let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { return nil }
        let executable = info["CFBundleExecutable"] as? String
        return IDeviceInstallPreflight(bundleIdentifier: bundleID) { installed in
            guard installed.applicationIdentifier != nil, let executable,
                  !executable.isEmpty, !executable.contains("/"), !executable.contains("\\"),
                  executable != ".", executable != ".." else { return }
            // Only an installed bundle-ID match needs the executable. Stream it
            // to scratch space so large games don't consume their size in RAM.
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("InstallPreflight-\(UUID().uuidString)", isDirectory: true)
            guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return }
            defer { try? FileManager.default.removeItem(at: directory) }
            let binary = directory.appendingPathComponent("Executable")
            guard (try? archive.extract(relativePath: executable, to: binary)) == true else { return }
            try IDeviceInstallPreflight.checkSigningIdentity(executableURL: binary, installed: installed)
        }
    }
}

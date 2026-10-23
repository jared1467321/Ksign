import Foundation
import IDeviceSwift

/// A prepared package is only a candidate, never uninstall permission. The
/// server progress observer must also see a new registration on this device.
final class ServerInstallTracking: @unchecked Sendable {
    private struct Candidate {
        let bundleIdentifier: String
        let applicationIdentifier: String
        let previousDate: Date?
        let preparedAt: Date
    }
    private let lock = NSLock()
    private var candidate: Candidate?

    /// Run off the main actor before offering the system install prompt.
    func prepare(packageURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        candidate = nil
        do {
            let archive = try ArchiveBackedApp(archiveURL: packageURL)
            guard let data = try archive.data(relativePath: "Info.plist", maximumBytes: 16 * 1024 * 1024),
                  let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let bundle = info["CFBundleIdentifier"] as? String, !bundle.isEmpty,
                  bundle != Bundle.main.bundleIdentifier,
                  let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
                  !executable.contains("/"), !executable.contains("\\"),
                  executable != ".", executable != ".." else { return }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("InstallTracking-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let binary = directory.appendingPathComponent("Executable")
            guard try archive.extract(relativePath: executable, to: binary),
                  let identity = try IDeviceInstallPreflight.signingApplicationIdentifier(executableURL: binary),
                  !identity.isEmpty else { return }
            candidate = Candidate(bundleIdentifier: bundle, applicationIdentifier: identity,
                previousDate: IDeviceInstalledAppDates.registrationDate(for: bundle), preparedAt: Date())
        } catch {
            NSLog("Asign couldn't prepare install tracking: %@", error.localizedDescription)
        }
    }

    func confirm() {
        lock.lock()
        defer { lock.unlock() }
        guard let candidate,
              let date = IDeviceInstalledAppDates.registrationDate(for: candidate.bundleIdentifier) else { return }
        do {
            try IDeviceManagedInstallRegistry.shared.recordObservedInstall(
                bundleIdentifier: candidate.bundleIdentifier,
                applicationIdentifier: candidate.applicationIdentifier,
                previousRegistrationDate: candidate.previousDate, registrationDate: date,
                preparedAt: candidate.preparedAt)
        } catch {
            NSLog("Asign couldn't record an observed install: %@", error.localizedDescription)
        }
    }
}

import Foundation
import IDeviceSwift
import NimbleExtensions
import UIKit

/// Tracks the signed IPA and the device's state before iOS begins installing.
/// Successful transfers are saved independently of the install progress UI.
final class ServerInstallTracking: @unchecked Sendable {
    private struct Candidate {
        let bundleIdentifier: String
        let applicationIdentifier: String
        let version: String?
    }
    private let lock = NSLock()
    private var candidate: Candidate?
    private var observation: IDeviceServerInstallObservation?
    private var servedAt: Date?

    var bundleIdentifier: String? {
        lock.lock()
        defer { lock.unlock() }
        return candidate?.bundleIdentifier
    }

    /// Run off the main actor before offering the system install prompt.
    func prepare(packageURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        candidate = nil
        observation = nil
        servedAt = nil
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
                version: info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String)
        } catch {
            NSLog("Asign couldn't prepare install tracking: %@", error.localizedDescription)
        }
    }

    @discardableResult
    func captureBaseline() -> IDeviceServerInstallObservation? {
        lock.lock()
        defer { lock.unlock() }
        if let observation, servedAt.map({ Date().timeIntervalSince($0) < 3600 }) ?? true { return observation }
        servedAt = nil
        guard let candidate else { return nil }

        let bundle = candidate.bundleIdentifier
        let previousPath = IDeviceInstalledAppDates.installationPath(for: bundle)
        let previousDate = IDeviceInstalledAppDates.registrationDate(for: bundle)
        let wasAbsent = UIApplication.installedAppPresence(bundle) == false
        let observation = IDeviceServerInstallObservation(bundleIdentifier: bundle,
            applicationIdentifier: candidate.applicationIdentifier, version: candidate.version, startedAt: Date(),
            previousRegistrationDate: previousDate, previousPath: previousPath, wasAbsent: wasAbsent)
        self.observation = observation
        return observation
    }

    func recordTransfer(_ observation: IDeviceServerInstallObservation) {
        let now = Date()
        lock.lock()
        if self.observation == observation, servedAt == nil { servedAt = now }
        lock.unlock()

        do {
            try IDeviceManagedInstallRegistry.shared.recordServerTransfer(observation, servedAt: now)
        } catch {
            NSLog("Asign couldn't record the server transfer: %@", error.localizedDescription)
        }
    }

    func hasNewRegistration() -> Bool {
        lock.lock()
        let transfer = (observation, servedAt)
        lock.unlock()
        guard let observation = transfer.0, let servedAt = transfer.1 else { return false }
        let bundle = observation.bundleIdentifier
        guard UIApplication.isAppInstalled(bundle) else { return false }
        return observation.sawNewCopy(path: IDeviceInstalledAppDates.installationPath(for: bundle),
            registrationDate: IDeviceInstalledAppDates.registrationDate(for: bundle), servedAt: servedAt)
    }
}

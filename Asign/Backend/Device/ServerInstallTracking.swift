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
    private var offeredObservation: IDeviceServerInstallObservation?
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
        offeredObservation = nil
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

    func resetBaseline() {
        lock.lock()
        defer { lock.unlock() }
        observation = nil
        offeredObservation = nil
        servedAt = nil
    }

    @discardableResult
    func captureBaseline() -> IDeviceServerInstallObservation? {
        lock.lock()
        defer { lock.unlock() }
        if let observation { return observation }
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

    func recordOffer(_ observation: IDeviceServerInstallObservation) throws {
        lock.lock()
        defer { lock.unlock() }
        guard offeredObservation != observation else { return }
        try IDeviceManagedInstallRegistry.shared.recordServerOffer(observation)
        if self.observation == observation { offeredObservation = observation }
    }

    func recordTransfer(_ observation: IDeviceServerInstallObservation) throws {
        let now = Date()
        try IDeviceManagedInstallRegistry.shared.recordServerTransfer(observation, servedAt: now)
        lock.lock()
        if self.observation == observation { servedAt = now }
        lock.unlock()

        // Progress can end before LaunchServices publishes the new copy.
        // Keep watching this transfer even if its row goes away or is retried.
        Task.detached(priority: .utility) { [self] in
            for _ in 0..<60 {
                if observeRegistration(observation, servedAt: now) { return }
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch { return }
            }
        }
    }

    func hasNewRegistration() -> Bool {
        lock.lock()
        let transfer = (observation, servedAt)
        lock.unlock()
        guard let observation = transfer.0, let servedAt = transfer.1 else { return false }
        return observeRegistration(observation, servedAt: servedAt)
    }

    private func observeRegistration(_ observation: IDeviceServerInstallObservation, servedAt: Date) -> Bool {
        let bundle = observation.bundleIdentifier
        guard UIApplication.installedAppPresence(bundle) != false else { return false }
        let path = IDeviceInstalledAppDates.installationPath(for: bundle)
        let date = IDeviceInstalledAppDates.registrationDate(for: bundle)
        let now = Date()
        guard observation.sawNewCopy(path: path, registrationDate: date, servedAt: servedAt, now: now) else {
            return false
        }
        do {
            try IDeviceManagedInstallRegistry.shared.recordServerRegistration(observation,
                path: path, registrationDate: date, observedAt: now)
        } catch {
            NSLog("Asign couldn't save the server registration: %@", error.localizedDescription)
            return false
        }
        return true
    }
}

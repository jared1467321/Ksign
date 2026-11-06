import CoreData
import Foundation
import IDeviceSwift
import NimbleExtensions
import UIKit

extension SigningPreflight {
    static func source(for app: AppInfoPresentable, options: Options? = nil) -> Source {
        Source(name: app.name ?? "Unknown App", recordedIdentifier: app.identifier,
               customIdentifier: options?.appIdentifier,
               archiveURL: nil, appDirectory: nil,
               libraryDirectory: Storage.shared.getUuidDirectory(for: app))
    }
}

@MainActor
enum SigningPreflightCoordinator {
    static func review(_ sources: [SigningPreflight.Source],
                       onContinue: @escaping (SigningPreflight.Report) -> Void,
                       onCancel: @escaping () -> Void) {
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                SigningPreflight.evaluate(sources.map(SigningPreflight.candidate), isInstalled: UIApplication.isAppInstalled)
            }.value
            guard !report.installed.isEmpty else { onContinue(report); return }
            var sections: [String] = []
            if !report.installed.isEmpty {
                sections.append("These bundle IDs are already installed:\n\n" +
                    report.installed.map(\.description).joined(separator: "\n") +
                    "\n\nYou can edit the bundle IDs or continue signing every eligible app. A differently signed copy cannot replace an App Store installation with the same bundle ID. Compatible updates remain eligible.")
            }
            let actions: [UIAlertAction]
            if report.eligibleIndices.isEmpty {
                actions = [UIAlertAction(title: "OK", style: .cancel) { _ in onCancel() }]
            } else {
                var choices = [UIAlertAction(title: "Cancel", style: .cancel) { _ in onCancel() }]
                if !report.installed.isEmpty {
                    choices.append(UIAlertAction(title: "Edit Bundle IDs", style: .default) { _ in onCancel() })
                }
                choices.append(UIAlertAction(title: "Continue Signing", style: .default) { _ in onContinue(report) })
                actions = choices
            }
            UIAlertController.showAlert(title: "Signing Review", message: sections.joined(separator: "\n\n"), actions: actions)
        }
    }

    struct Handoff {
        var appIDs: [String] = []
        var withheld: [SigningPreflight.Issue] = []
    }

    /// Keep every successfully signed package. Only compatible, verified native
    /// candidates enter the install drawer, identified by their exact library IDs.
    static func prepareInstallation(_ appIDs: [String]) async -> Handoff {
        var result = Handoff()
        let request = NSFetchRequest<Signed>(entityName: "Signed")
        request.predicate = NSPredicate(format: "uuid IN %@", appIDs)
        let signed = (try? Storage.shared.context.fetch(request)) ?? []
        let byID = Dictionary(signed.compactMap { app in app.uuid.map { ($0, app) } }, uniquingKeysWith: { first, _ in first })
        let manager = DeviceInstallationManager.shared
        let workflow = UUID()
        var retained = false
        defer { if retained { manager.releaseWorkflow(workflow) } }
        for id in appIDs {
            guard let app = byID[id] else {
                result.withheld.append(.init(name: byID[id]?.name ?? "Signed App", reason: "The signed package could not be read. It has not been queued for installation."))
                continue
            }
            do {
                let snapshot = SigningAppSnapshot(app)
                let preflight = try await Task.detached(priority: .userInitiated) {
                    let packageURL = Storage.shared.getArchiveURL(for: snapshot)
                    let appDirectory = packageURL == nil ? Storage.shared.getAppDirectory(for: snapshot) : nil
                    if let packageURL { return try DeviceInstallPreflight.inspect(packageURL) }
                    if let appDirectory { return try DeviceInstallPreflight.inspect(appDirectory: appDirectory) }
                    throw ArchiveBackedAppError.rootAppNotFound
                }.value
                if UserDefaults.standard.integer(forKey: "Feather.installationMethod") == 1,
                   let preflight, UIApplication.isAppInstalled(preflight.bundleIdentifier) {
                    if !retained {
                        manager.clearSetupFailure()
                        manager.retainWorkflow(workflow)
                        retained = true
                    }
                    try await manager.validate(preflight)
                }
                result.appIDs.append(id)
            } catch {
                result.withheld.append(.init(name: app.name ?? "Signed App", reason: error.localizedDescription))
            }
        }
        return result
    }
}

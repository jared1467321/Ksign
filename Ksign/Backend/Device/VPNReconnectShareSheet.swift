import UIKit
import NimbleExtensions

@MainActor
enum VPNReconnectShareSheet {
    private static weak var controller: UIActivityViewController?
    private static var diagnostics: Diagnostics?

    static func present(shortcutName: String, completion: @escaping @MainActor (Bool) -> Void) -> Bool {
        let diagnostic = Diagnostics()
        diagnostic.log("Requested shortcut=\(shortcutName.debugDescription), iOS=\(UIDevice.current.systemVersion), appState=\(UIApplication.shared.applicationState.rawValue)")
        diagnostic.log("Ksign version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"), build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")")
        guard UIApplication.shared.applicationState == .active else {
            diagnostic.log("Presentation refused: Ksign is not active")
            return false
        }
        guard controller == nil else {
            diagnostic.log("Presentation refused: another reconnect share sheet is already tracked")
            return false
        }
        guard let presenter = UIApplication.topViewController() else {
            diagnostic.log("Presentation refused: no presenting view controller")
            return false
        }
        diagnostic.log("Presenter=\(String(describing: type(of: presenter))), attachedToWindow=\(presenter.viewIfLoaded?.window != nil), beingDismissed=\(presenter.isBeingDismissed), beingPresented=\(presenter.isBeingPresented)")
        guard presenter.viewIfLoaded?.window != nil,
              !presenter.isBeingDismissed, !presenter.isBeingPresented else {
            diagnostic.log("Presentation refused: presenter is detached or transitioning")
            return false
        }

        // Text lets a shortcut accepting Text/Anything appear in the system
        // share sheet.
        let sheet = UIActivityViewController(
            activityItems: ["Reconnect VPN using \(shortcutName)"], applicationActivities: nil)
        sheet.excludedActivityTypes = [.copyToPasteboard, .print, .assignToContact,
                                      .saveToCameraRoll, .addToReadingList]
        sheet.completionWithItemsHandler = { [weak sheet] activityType, completed, returnedItems, error in
            Task { @MainActor in
                diagnostic.log("Completion callback: activity=\(activityType?.rawValue ?? "none"), completed=\(completed), returnedItemCount=\(returnedItems?.count ?? 0), error=\(error == nil ? "none" : "present"), trackedSheet=\(controller === sheet)")
                if let error { diagnostic.logError(error as NSError) }
                diagnostic.stop()
                if diagnostics === diagnostic { diagnostics = nil }
                if controller === sheet { controller = nil }
                completion(completed)
            }
        }
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                        y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        controller = sheet
        diagnostics?.stop()
        diagnostics = diagnostic
        diagnostic.observeLifecycle()
        diagnostic.log("Presenting share sheet with one text item")
        presenter.present(sheet, animated: true) { [weak sheet] in
            diagnostic.log("Presentation animation finished: attachedToWindow=\(sheet?.viewIfLoaded?.window != nil), hasPresenter=\(sheet?.presentingViewController != nil)")
        }
        // This is an observation, not a timeout: choosing/running a shortcut
        // may legitimately take longer. Do not dismiss or retry the sheet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak diagnostic, weak sheet] in
            guard let diagnostic, diagnostics === diagnostic else { return }
            diagnostic.log("Still awaiting completion callback after 15 seconds; attachedToWindow=\(sheet?.viewIfLoaded?.window != nil), appState=\(UIApplication.shared.applicationState.rawValue). This does not confirm whether the shortcut started.")
        }
        return true
    }

    static func dismiss() {
        let sheet = controller
        diagnostics?.log("Ksign requested dismissal; sheetTracked=\(sheet != nil)")
        diagnostics?.stop()
        diagnostics = nil
        controller = nil
        sheet?.dismiss(animated: true)
    }

    /// Uses stdout, the same stream captured by the in-app signing logs.
    @MainActor
    private final class Diagnostics {
        private let id = String(UUID().uuidString.prefix(8))
        private let started = ProcessInfo.processInfo.systemUptime
        private var observers: [NSObjectProtocol] = []

        func log(_ message: String) {
            let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started)
            print("[VPN Reconnect][Share \(id)][+\(elapsed)s] \(message)")
        }

        func logError(_ error: NSError, depth: Int = 0) {
            log("\(depth == 0 ? "Error" : "Underlying error"): domain=\(error.domain), code=\(error.code), description=\(error.localizedDescription)")
            if let reason = error.localizedFailureReason { log("Failure reason: \(reason)") }
            if let suggestion = error.localizedRecoverySuggestion { log("Recovery suggestion: \(suggestion)") }
            if depth < 4, let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                logError(underlying, depth: depth + 1)
            }
        }

        func observeLifecycle() {
            for name in [UIApplication.willResignActiveNotification,
                         UIApplication.didEnterBackgroundNotification,
                         UIApplication.didBecomeActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.log("App lifecycle: \(name.rawValue)") }
                })
            }
        }

        func stop() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }
    }
}

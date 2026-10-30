import UIKit
import NimbleExtensions

@MainActor
enum VPNReconnectShareSheet {
    private static weak var controller: UIActivityViewController?

    static func present(shortcutName: String, completion: @escaping @MainActor (Bool) -> Void) -> Bool {
        let diagnosticID = UUID().uuidString
        VPNReconnectDiagnostics.record("sheet[\(diagnosticID)] presentation requested; shortcut=\(shortcutName)")
        guard UIApplication.shared.applicationState == .active,
              controller == nil,
              let presenter = UIApplication.topViewController(),
              presenter.viewIfLoaded?.window != nil,
              !presenter.isBeingDismissed, !presenter.isBeingPresented else {
            VPNReconnectDiagnostics.record("sheet[\(diagnosticID)] presentation rejected; existingSheet=\(controller != nil); presenter=\(describe(UIApplication.topViewController()))")
            return false
        }

        VPNReconnectDiagnostics.record("sheet[\(diagnosticID)] presenter=\(describe(presenter)); payload=String; excluded activities=copy,print,contact,cameraRoll,readingList")

        // Text lets a shortcut accepting Text/Anything appear in the system
        // share sheet.
        let sheet = UIActivityViewController(
            activityItems: ["Reconnect VPN using \(shortcutName)"], applicationActivities: nil)
        sheet.excludedActivityTypes = [.copyToPasteboard, .print, .assignToContact,
                                      .saveToCameraRoll, .addToReadingList]
        sheet.completionWithItemsHandler = { [weak sheet] activity, completed, returnedItems, error in
            Task { @MainActor in
                let returnedTypes = (returnedItems ?? []).map { String(reflecting: type(of: $0)) }
                VPNReconnectDiagnostics.record("sheet[\(diagnosticID)] completion; activity=\(activity?.rawValue ?? "nil"); completed=\(completed); returnedItemTypes=\(returnedTypes); matchesCurrentSheet=\(controller === sheet); controller=\(describe(sheet))")
                if let error {
                    recordError(error as NSError, diagnosticID: diagnosticID)
                } else {
                    VPNReconnectDiagnostics.record("sheet[\(diagnosticID)] completion error=nil")
                }
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
        presenter.present(sheet, animated: true) { [weak sheet] in
            VPNReconnectDiagnostics.record("sheet[\(diagnosticID)] presentation animation finished; controller=\(describe(sheet))")
        }
        return true
    }

    static func dismiss() {
        let sheet = controller
        VPNReconnectDiagnostics.record("sheet dismissal requested by Asign; controller=\(describe(sheet))")
        controller = nil
        sheet?.dismiss(animated: true)
    }

    private static func describe(_ viewController: UIViewController?) -> String {
        guard let viewController else { return "nil" }
        let presented = viewController.presentedViewController.map { String(reflecting: type(of: $0)) } ?? "nil"
        return "\(String(reflecting: type(of: viewController))) "
            + "inWindow=\(viewController.viewIfLoaded?.window != nil) "
            + "beingPresented=\(viewController.isBeingPresented) "
            + "beingDismissed=\(viewController.isBeingDismissed) presented=\(presented)"
    }

    private static func recordError(_ error: NSError, diagnosticID: String, depth: Int = 0) {
        VPNReconnectDiagnostics.record("sheet[\(diagnosticID)] error[\(depth)]; domain=\(error.domain); code=\(error.code); description=\(error.localizedDescription); reason=\(error.localizedFailureReason ?? "nil"); recovery=\(error.localizedRecoverySuggestion ?? "nil")")
        if depth < 3, let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            recordError(underlying, diagnosticID: diagnosticID, depth: depth + 1)
        }
    }
}

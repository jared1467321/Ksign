import UIKit
import NimbleExtensions

@MainActor
enum VPNReconnectShareSheet {
    private static weak var controller: UIActivityViewController?

    static func present(shortcutName: String, completion: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard UIApplication.shared.applicationState == .active,
              controller == nil,
              let presenter = UIApplication.topViewController(),
              presenter.viewIfLoaded?.window != nil,
              !presenter.isBeingDismissed, !presenter.isBeingPresented else { return false }

        // Text lets a shortcut accepting Text/Anything appear in the system
        // share sheet.
        let sheet = UIActivityViewController(
            activityItems: ["Reconnect VPN using \(shortcutName)"], applicationActivities: nil)
        sheet.excludedActivityTypes = [.copyToPasteboard, .print, .assignToContact,
                                      .saveToCameraRoll, .addToReadingList]
        sheet.completionWithItemsHandler = { [weak sheet] _, completed, _, _ in
            Task { @MainActor in
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
        presenter.present(sheet, animated: true)
        return true
    }

    static func dismiss() {
        let sheet = controller
        controller = nil
        sheet?.dismiss(animated: true)
    }
}

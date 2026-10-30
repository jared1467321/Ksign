import Combine
import Foundation
#if canImport(UIKit)
import UIKit
import UserNotifications
#endif

enum VPNReconnectPresentation: String, CaseIterable, Identifiable {
    case shareSheet, automatic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shareSheet: return "Share Sheet"
        case .automatic: return "Open Shortcuts Automatically"
        }
    }
}

/// Hands control to a user-created shortcut only after device work has drained.
/// A completed handoff does not confirm that the other VPN connected.
@MainActor
final class VPNReconnectCoordinator: ObservableObject {
    static let shared = VPNReconnectCoordinator()
    nonisolated static let enabledKey = "Ksign.reconnectVPNAfterInstallation"
    nonisolated static let shortcutNameKey = "Ksign.vpnReconnectShortcutName"
    nonisolated static let presentationKey = "Ksign.vpnReconnectPresentation"
    nonisolated static let defaultShortcutName = "Restore Tailscale"
    nonisolated static let notificationIdentifier = "ksign.vpnReconnect"
    private static let pendingNameKey = "Ksign.pendingVPNReconnectName"
    private static let pendingIDKey = "Ksign.pendingVPNReconnectID"

    @Published private(set) var pendingShortcutName: String?
    @Published private(set) var notice: String?
    private var requestID: String?
    private var tappedRequestID: String?
    private var deviceWorkActive = false
    private var userChoiceRequested = false
    private var openingShortcut = false
    private var shareSheetRequestID: String?
    private let defaults: UserDefaults
    private let isForeground: @MainActor () -> Bool
    private let openShortcut: @MainActor (URL) async -> Bool
    private let notify: @MainActor (String, String) async -> Bool
    private let removeNotification: @MainActor (String) -> Void
    private let presentShareSheet: @MainActor (String, @escaping @MainActor (Bool) -> Void) -> Bool
    private let dismissShareSheet: @MainActor () -> Void

    var presentation: VPNReconnectPresentation {
        VPNReconnectPresentation(rawValue: defaults.string(forKey: Self.presentationKey) ?? "") ?? .shareSheet
    }

    init(defaults: UserDefaults = .standard,
         isForeground: @escaping @MainActor () -> Bool = { VPNReconnectCoordinator.appIsActive },
         openShortcut: @escaping @MainActor (URL) async -> Bool = { await VPNReconnectCoordinator.open($0) },
         notify: @escaping @MainActor (String, String) async -> Bool = { await VPNReconnectCoordinator.sendNotification(name: $0, id: $1) },
         removeNotification: @escaping @MainActor (String) -> Void = { VPNReconnectCoordinator.clearNotification(id: $0) },
         presentShareSheet: @escaping @MainActor (String, @escaping @MainActor (Bool) -> Void) -> Bool = {
             VPNReconnectCoordinator.showShareSheet(name: $0, completion: $1)
         },
         dismissShareSheet: @escaping @MainActor () -> Void = { VPNReconnectCoordinator.closeShareSheet() }) {
        self.defaults = defaults
        self.isForeground = isForeground
        self.openShortcut = openShortcut
        self.notify = notify
        self.removeNotification = removeNotification
        self.presentShareSheet = presentShareSheet
        self.dismissShareSheet = dismissShareSheet
        if defaults.bool(forKey: Self.enabledKey),
           let name = defaults.string(forKey: Self.pendingNameKey),
           let id = defaults.string(forKey: Self.pendingIDKey) {
            pendingShortcutName = name
            requestID = id
        }
    }

    static func shortcutURL(name: String) -> URL? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }

    func beginDeviceWork(requiresUserChoice: Bool = false) {
        deviceWorkActive = true
        // Inventory refreshes leave the existing reconnect reminder available
        // without presenting a sheet or opening Shortcuts automatically.
        userChoiceRequested = userChoiceRequested || requiresUserChoice
        clearPendingRequest()
        notice = nil
    }

    func deviceWorkFinished(restoreVPN: Bool) async {
        deviceWorkActive = false
        let requiresChoice = userChoiceRequested
        userChoiceRequested = false
        guard restoreVPN else { return }
        await requestReconnect(automaticallyPresent: !requiresChoice)
    }

    func testShortcut() async {
        guard !deviceWorkActive else { return }
        await requestReconnect()
    }

    func disable() {
        clearPendingRequest()
        notice = nil
    }

    private func requestReconnect(automaticallyPresent: Bool = true) async {
        guard defaults.bool(forKey: Self.enabledKey), !deviceWorkActive, !openingShortcut else { return }
        let name = (defaults.string(forKey: Self.shortcutNameKey) ?? Self.defaultShortcutName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.shortcutURL(name: name) != nil else {
            notice = "Enter the name of your VPN reconnect shortcut."
            return
        }
        clearPendingRequest()
        let id = UUID().uuidString
        requestID = id
        pendingShortcutName = name
        defaults.set(name, forKey: Self.pendingNameKey)
        defaults.set(id, forKey: Self.pendingIDKey)
        if isForeground() {
            if automaticallyPresent { await runPendingShortcut() }
            else { notice = "Tap Reconnect VPN when you want to run \(name)." }
        } else {
            notice = "Tap the reconnect notification, or return to Asign and tap Reconnect VPN."
            let delivered = await notify(name, id)
            // New work may have invalidated this request while notification
            // delivery was in flight. Remove that stale notification too.
            guard requestID == id else {
                removeNotification(id)
                return
            }
            if !delivered {
                notice = "Return to Asign and tap Reconnect VPN. Enable Asign notifications for a reminder when installation finishes in the background."
            }
        }
    }

    func runPendingShortcut() async {
        guard !deviceWorkActive, !openingShortcut, shareSheetRequestID == nil, isForeground(),
              defaults.bool(forKey: Self.enabledKey),
              let id = requestID, let name = pendingShortcutName else { return }
        if presentation == .shareSheet {
            shareSheetRequestID = id
            let presented = presentShareSheet(name) { [weak self] completed in
                self?.shareSheetFinished(id: id, completed: completed)
            }
            if presented {
                notice = nil
            } else {
                shareSheetRequestID = nil
                notice = "Could not show the share sheet. Tap Reconnect VPN to try again."
            }
            // Installation cleanup must not wait for the user's selection.
            return
        }
        guard let url = Self.shortcutURL(name: name) else { return }
        openingShortcut = true
        let opened = await openShortcut(url)
        openingShortcut = false
        guard requestID == id else { return }
        if opened {
            clearPendingRequest()
            notice = nil
        } else {
            notice = "Could not open Shortcuts. Make sure it is installed, then tap Reconnect VPN to try again."
        }
    }

    private func shareSheetFinished(id: String, completed: Bool) {
        guard requestID == id, shareSheetRequestID == id else { return }
        shareSheetRequestID = nil
        if completed {
            clearPendingRequest()
            notice = nil
        } else {
            notice = "Tap Reconnect VPN and select your shortcut. If it is missing, enable Show in Share Sheet and allow Text input in its details."
        }
    }

    func notificationTapped(id: String) async {
        guard requestID == id, !deviceWorkActive else { return }
        tappedRequestID = id
        await appBecameActive()
    }

    func appBecameActive() async {
        guard isForeground(), let tappedRequestID, tappedRequestID == requestID else { return }
        self.tappedRequestID = nil
        await runPendingShortcut()
    }

    private func clearPendingRequest() {
        let hadShareSheet = shareSheetRequestID != nil
        shareSheetRequestID = nil
        if let requestID { removeNotification(requestID) }
        requestID = nil
        tappedRequestID = nil
        pendingShortcutName = nil
        defaults.removeObject(forKey: Self.pendingNameKey)
        defaults.removeObject(forKey: Self.pendingIDKey)
        if hadShareSheet { dismissShareSheet() }
    }

    func requestNotificationPermission() async {
        #if canImport(UIKit)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        #endif
    }

    private static var appIsActive: Bool {
        #if canImport(UIKit)
        return UIApplication.shared.applicationState == .active
        #else
        return false
        #endif
    }

    private static func open(_ url: URL) async -> Bool {
        #if canImport(UIKit)
        return await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { continuation.resume(returning: $0) }
        }
        #else
        return false
        #endif
    }

    private static func showShareSheet(name: String, completion: @escaping @MainActor (Bool) -> Void) -> Bool {
        #if canImport(UIKit)
        return VPNReconnectShareSheet.present(shortcutName: name, completion: completion)
        #else
        return false
        #endif
    }

    private static func closeShareSheet() {
        #if canImport(UIKit)
        VPNReconnectShareSheet.dismiss()
        #endif
    }

    private static func sendNotification(name: String, id: String) async -> Bool {
        #if canImport(UIKit)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
                settings.authorizationStatus == .provisional ||
                settings.authorizationStatus == .ephemeral else { return false }
        let content = UNMutableNotificationContent()
        content.title = "Reconnect your VPN"
        content.body = "Asign has finished using its local VPN. Tap to reconnect using \(name)."
        content.sound = .default
        content.userInfo = ["ksignVPNReconnectID": id]
        do {
            try await center.add(UNNotificationRequest(identifier: notificationIdentifier + "." + id,
                                                       content: content, trigger: nil))
            return true
        } catch { return false }
        #else
        return false
        #endif
    }

    private static func clearNotification(id: String) {
        #if canImport(UIKit)
        let center = UNUserNotificationCenter.current()
        let identifier = notificationIdentifier + "." + id
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        #endif
    }
}

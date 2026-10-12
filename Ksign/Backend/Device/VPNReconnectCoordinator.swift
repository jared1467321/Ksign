import Combine
import Foundation
import UIKit

@MainActor
final class VPNReconnectCoordinator: ObservableObject {
    static let shared = VPNReconnectCoordinator()
    enum Status: Equatable { case idle, waiting, opening, requested, failed(String) }

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "Ksign.vpnReconnect.enabled")
            if !isEnabled { cancelPending() }
        }
    }
    @Published var shortcutName: String {
        didSet { UserDefaults.standard.set(shortcutName, forKey: "Ksign.vpnReconnect.shortcutName") }
    }
    @Published private(set) var status: Status = .idle
    private var pending = false
    private var openingID: UUID?
    private var activeObserver: NSObjectProtocol?

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: "Ksign.vpnReconnect.enabled")
        shortcutName = UserDefaults.standard.string(forKey: "Ksign.vpnReconnect.shortcutName") ?? "Reconnect Tailscale"
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tryPending() }
        }
    }

    deinit {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    func cancelPending() {
        pending = false
        openingID = nil
        status = .idle
    }

    func request() {
        guard isEnabled else { return }
        pending = true
        status = .waiting
        tryPending()
    }

    func tryPending() {
        guard pending, isEnabled, openingID == nil,
              UIApplication.shared.applicationState == .active,
              !DeviceInstallationManager.shared.isBusy,
              !InstallSession.shared.jobs.contains(where: { $0.phase == .queued || $0.phase == .running }) else { return }
        guard let url = VPNReconnectRequest.url(shortcutName: shortcutName) else {
            pending = false
            status = .failed("Enter the name of your reconnect shortcut in Installation settings.")
            return
        }
        pending = false
        let id = UUID()
        openingID = id
        status = .opening
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            Task { @MainActor in
                guard let self, self.openingID == id else { return }
                self.openingID = nil
                // URL acceptance is not proof that Tailscale has connected.
                // Shortcuts displays action/permission errors in its own UI.
                self.status = opened ? .requested : .failed("iOS could not open Shortcuts. Install or enable Shortcuts, then try again.")
            }
        }
    }
}

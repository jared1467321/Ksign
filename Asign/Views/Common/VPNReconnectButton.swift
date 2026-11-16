import SwiftUI
import NimbleViews

struct VPNReconnectButton: View {
    @AppStorage(VPNReconnectCoordinator.shortcutNameKey) private var shortcutName = VPNReconnectCoordinator.defaultShortcutName
    @ObservedObject private var manager = DeviceInstallationManager.shared

    var body: some View {
        Button {
            Task { await manager.runVPNReconnectShortcut() }
        } label: {
            NBButton("VPN", systemImage: "", style: .text)
                .font(.subheadline.weight(.semibold))
        }
        .disabled(!manager.canReconnectVPN || VPNReconnectCoordinator.shortcutURL(name: shortcutName) == nil)
        .accessibilityLabel("Reconnect VPN")
    }
}

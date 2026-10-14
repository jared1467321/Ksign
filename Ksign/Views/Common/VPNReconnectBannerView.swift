import SwiftUI
import NimbleViews

/// Keeps a dismissed share sheet or a background reconnect within easy reach.
struct VPNReconnectBannerView: View {
    @ObservedObject private var reconnect = VPNReconnectCoordinator.shared
    @ObservedObject private var manager = DeviceInstallationManager.shared

    var body: some View {
        if let name = reconnect.pendingShortcutName {
            HStack(spacing: 12) {
                Button {
                    Task { await reconnect.runPendingShortcut() }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Reconnect VPN", systemImage: "network")
                            .font(.subheadline.weight(.semibold))
                        Text(name).font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!manager.canReconnectVPN)
                Button { reconnect.disable() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .accessibilityLabel("Dismiss VPN reconnect reminder")
            }
            .buttonStyle(.plain)
            .nbThemeForeground(.text)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .nbThemeBackground(.elevated)
        }
    }
}

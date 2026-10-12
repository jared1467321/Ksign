import SwiftUI

struct VPNReconnectSettingsView: View {
    @ObservedObject private var reconnect = VPNReconnectCoordinator.shared
    @ObservedObject private var manager = DeviceInstallationManager.shared

    var body: some View {
        Section {
            Toggle("Reconnect VPN After Installation", isOn: $reconnect.isEnabled)
            if reconnect.isEnabled {
                TextField("Shortcut name", text: $reconnect.shortcutName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Test Reconnect Shortcut") { reconnect.request() }
                    .disabled(manager.isBusy || InstallSession.shared.isActive)
            }
            DisclosureGroup("Set Up Tailscale Reconnect") {
                Text("1. In Apple's Shortcuts app, create a shortcut named Reconnect Tailscale.\n2. Add Tailscale's Connect action. Use Connect rather than Toggle.\n3. Run it once and allow any permission prompts.\n4. Enable Reconnect VPN After Installation here. If you use a different shortcut name, enter it above.")
                    .font(.callout)
                    .textSelection(.enabled)
            }
        } footer: {
            Text("When enabled, Ksign opens your shortcut after disabling its temporary VPN. If Ksign is in the background, it waits until you return. The shortcut runs after each built-in workflow, even if your usual VPN was previously off. Ksign cannot check whether another app's VPN connected.")
        }
    }
}

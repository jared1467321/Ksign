import SwiftUI
import NimbleViews

struct DeviceConnectionSettingsView: View {
    @ObservedObject private var manager = DeviceInstallationManager.shared
    @State private var confirmReset = false

    var body: some View {
        Section {
            Picker("Connection", selection: $manager.mode) {
                ForEach(DeviceConnectionMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .disabled(manager.isBusy || InstallSession.shared.isActive)
        } footer: {
            Text("Built-in Connection manages a local VPN inside Ksign. Creating a pairing on this device requires iOS 27 or later and approval in Settings. The VPN requires a compatible signing profile and may replace another active VPN.")
        }
        if manager.mode == .manual {
            TunnelView()
        } else {
            Section {
                DeviceConnectionSetupView(alwaysVisible: true)
                Button("Forget Built-in Pairing", role: .destructive) { confirmReset = true }
                    .disabled(manager.isBusy || InstallSession.shared.isActive)
            }
            .confirmationDialog("Forget this device's saved pairing?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Forget Pairing", role: .destructive) { Task { await manager.resetPairing() } }
            } message: {
                Text("The next built-in installation will ask you to pair again. To remove trust from iOS too, use Developer settings.")
            }
            VPNReconnectSettingsView()
        }
    }
}

private struct VPNReconnectSettingsView: View {
    @AppStorage(VPNReconnectCoordinator.enabledKey) private var enabled = false
    @AppStorage(VPNReconnectCoordinator.shortcutNameKey) private var shortcutName = VPNReconnectCoordinator.defaultShortcutName
    @ObservedObject private var reconnect = VPNReconnectCoordinator.shared
    @ObservedObject private var manager = DeviceInstallationManager.shared

    var body: some View {
        Section {
            Toggle("Reconnect VPN after installation", isOn: $enabled)
            if enabled {
                TextField("Shortcut name", text: $shortcutName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Test Reconnect Shortcut") {
                    Task { await manager.testVPNReconnectShortcut() }
                }
                .disabled(!manager.canReconnectVPN || InstallSession.shared.isActive ||
                          shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if reconnect.pendingShortcutName != nil {
                    Button("Reconnect VPN") { Task { await reconnect.runPendingShortcut() } }
                        .disabled(!manager.canReconnectVPN || InstallSession.shared.isActive)
                }
                if let notice = reconnect.notice {
                    Text(notice).font(.footnote)
                }
            }
        } header: {
            Text("Restore your VPN")
        } footer: {
            Text("In Shortcuts, create a shortcut named Restore Tailscale with Tailscale's Connect action, or enter the name of your own VPN shortcut here. Ksign runs it after all device work ends and its local VPN disconnects. This briefly opens Shortcuts. If Ksign finishes in the background, tap the reconnect notification. You can add Open App → Ksign as the shortcut's last action to return here.")
        }
        .onChange(of: enabled) { enabled in
            if enabled { Task { await reconnect.requestNotificationPermission() } }
            else { reconnect.disable() }
        }
    }
}

struct DeviceConnectionSetupView: View {
    @ObservedObject private var manager = DeviceInstallationManager.shared
    @ObservedObject private var pairing = DevicePairingService.shared
    var alwaysVisible = false

    var body: some View {
        if alwaysVisible || manager.showsSetup {
            VStack(alignment: .leading, spacing: 12) {
                Label("Device Connection", systemImage: "iphone.and.arrow.forward")
                    .font(.headline)
                if let notice = manager.setupNotice {
                    Text(notice).font(.callout)
                }
                switch manager.phase {
                case .pairing:
                    Text("Allow Local Network access. Open Settings → Privacy & Security → Developer Mode, enable it if needed, then choose Pair with Ksign. Return here after entering the code.")
                    if let pin = pairing.pin {
                        Text(pin).font(.largeTitle.monospaced().bold()).textSelection(.enabled)
                        Text("Enter this code in Settings. It also appears in Ksign's system progress activity when available.")
                            .font(.footnote)
                    } else {
                        ProgressView("Waiting for you to select Pair with Ksign…")
                    }
                    Button("Cancel Setup", role: .cancel) { manager.cancelSetup() }
                case .connecting:
                    ProgressView("Connecting to this device…")
                    Text("Allow Ksign to add its VPN configuration if iOS asks.").font(.footnote)
                    Button("Cancel Setup", role: .cancel) { manager.cancelSetup() }
                case .failed(let message):
                    Text(message).font(.callout)
                    Button("Retry Setup") { Task { await manager.setUp() } }
                        .disabled(manager.isBusy)
                    Text("After setup succeeds, retry any failed apps in the install drawer.").font(.footnote)
                case .ready:
                    Label("Connected", systemImage: "checkmark.circle")
                case .configured:
                    Label("Setup complete", systemImage: "checkmark.circle")
                    Text("Ksign will reconnect automatically when you install apps.").font(.footnote)
                case .idle:
                    Text("Ksign connects automatically when you install apps. You can also set up and check the connection now.")
                    Button("Set Up Connection") { Task { await manager.setUp() } }
                        .disabled(manager.isBusy)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .nbThemeForeground(.text)
        }
    }
}

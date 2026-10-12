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
            Text("Built-in Connection manages a temporary local VPN inside Ksign and disables it when the installation workflow ends. Creating a pairing on this device requires iOS 27 or later and approval in Settings. The VPN requires a compatible signing profile and may replace another active VPN. You may need to reconnect your usual VPN afterward.")
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
                case .disconnecting:
                    ProgressView("Disconnecting installation VPN…")
                case .cleanupFailed(let message):
                    Text(message).font(.callout)
                    Button("Disconnect VPN") { manager.retryDisconnect() }
                        .disabled(manager.isBusy)
                case .failed(let message):
                    Text(message).font(.callout)
                    Button("Retry Setup") { Task { await manager.setUp() } }
                        .disabled(manager.isBusy)
                    Text("After setup succeeds, retry any failed apps in the install drawer.").font(.footnote)
                case .ready:
                    Label("Connected", systemImage: "checkmark.circle")
                case .configured:
                    Label("Setup complete", systemImage: "checkmark.circle")
                    Text("Ksign's temporary VPN is off. It will reconnect automatically when you install apps. If you use another VPN, reconnect it in that app or iOS VPN Settings.").font(.footnote)
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

import SwiftUI
import NimbleViews
import NimbleExtensions
import IDeviceSwift

struct DeviceConnectionSettingsView: View {
    @AppStorage(NativeInstallLimit.preferenceKey) private var activeAppLimit = NativeInstallLimit.defaultValue
    @ObservedObject private var manager = DeviceInstallationManager.shared
    private let session = InstallSession.shared
    @State private var isSessionActive = InstallSession.shared.isActive
    @ObservedObject private var reconnect = VPNReconnectCoordinator.shared
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var confirmReset = false
    @State private var showsGuide = false
    @State private var hasSavedPairing = false

    private var controlsDisabled: Bool { manager.isBusy || isSessionActive }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Device connection").font(.subheadline.weight(.semibold))
                Picker("Device connection", selection: $manager.mode) {
                    Text("Built-in").tag(DeviceConnectionMode.builtIn)
                    Text("Manual").tag(DeviceConnectionMode.manual)
                }
                .pickerStyle(.segmented)
                .disabled(controlsDisabled)
            }
            .connectionCard()

            installLimit

            if manager.mode == .builtIn {
                connectionOverview
                if manager.showsSetup {
                    DeviceConnectionSetupView(alwaysVisible: true)
                        .connectionCard()
                }
                actions
                if reconnect.pendingShortcutName != nil {
                    Button {
                        Task { await reconnect.runPendingShortcut() }
                    } label: {
                        Label("Reconnect VPN now", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!manager.canReconnectVPN || isSessionActive)
                }
                DeviceUploadPerformanceView()
                connectionStatus
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ConnectionIcon(symbol: "externaldrive.badge.person.crop")
                    Text("Bring your own connection").font(.title3.bold())
                    Text("Import a pairing file and connect your local VPN before installing.")
                        .font(.subheadline)
                        .nbThemeForeground(.textSecondary)
                    NavigationLink {
                        NBList("Manual Connection") { TunnelView() }
                            .buttonStyle(.automatic)
                    } label: {
                        Label("Manage pairing file", systemImage: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(controlsDisabled)
                }
                .connectionCard()
                DeviceUploadPerformanceView()
            }
        }
        .nbThemeForeground(.text)
        .nbThemeTint(.accent)
        .buttonStyle(.plain)
        .onReceive(session.isActivePublisher) { isSessionActive = $0 }
        .task { refreshPairingStatus() }
        .onChange(of: manager.phase) { _ in refreshPairingStatus() }
        .confirmationDialog("Forget this device's saved pairing?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Forget Pairing", role: .destructive) { Task { await manager.resetPairing() } }
        } message: {
            Text("The next built-in installation will ask you to pair again. To remove trust from iOS too, use Developer settings.")
        }
        .sheet(isPresented: $showsGuide) {
            NBNavigationView("Pairing Guide", displayMode: .inline) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ConnectionIcon(symbol: "link")
                        Text("Pair once. Install anytime.").font(.title2.bold())
                        Text("Ksign saves your pairing on this device and manages a local VPN whenever you install apps.")
                            .nbThemeForeground(.textSecondary)
                        DevicePairingInstructions()
                        Label("Creating a new pairing requires iOS 27 or later. On earlier versions, import a pairing file using Manual Connection.", systemImage: "info.circle")
                            .font(.footnote)
                            .nbThemeForeground(.textSecondary)
                        Label("The local VPN needs a compatible signing profile and can replace your active VPN. Use Restore VPN to reconnect after installation.", systemImage: "network")
                            .font(.footnote)
                            .nbThemeForeground(.textSecondary)
                        Text("If the device changes or Developer Mode is reset, forget the pairing and set it up again.")
                            .font(.footnote)
                            .nbThemeForeground(.textSecondary)
                    }
                    .padding(24)
                    .frame(maxWidth: 600, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsGuide = false }
                    }
                }
            }
        }
    }

    private var installLimit: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Installation limit").font(.subheadline.weight(.semibold))
            Stepper(value: Binding(
                get: { NativeInstallLimit.normalized(activeAppLimit) },
                set: { session.setNativeInstallLimit($0) }
            ), in: NativeInstallLimit.allowedValues) {
                HStack {
                    Text("Maximum active apps")
                    Spacer()
                    Text("\(NativeInstallLimit.normalized(activeAppLimit))")
                        .monospacedDigit()
                }
            }
            Text("Uploading and installing apps share this limit. Lowering it lets active apps finish before new apps start.")
                .font(.caption)
                .nbThemeForeground(.textSecondary)
        }
        .connectionCard()
        .onChange(of: activeAppLimit) { session.setNativeInstallLimit($0) }
    }

    private var connectionOverview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                ConnectionIcon(symbol: "iphone.and.arrow.forward")
                Spacer()
                Text("BUILT-IN")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .nbThemeForeground(.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .nbThemeBackground(.accent, opacity: 0.12, in: Capsule())
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(overviewTitle).font(.title2.bold())
                Text(overviewDetail)
                    .font(.subheadline)
                    .nbThemeForeground(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .connectionCard(highlighted: true)
        .accessibilityElement(children: .combine)
    }

    private var overviewTitle: String {
        switch manager.phase {
        case .ready: return "Device connected"
        case .configured: return "Ready when you are"
        case .pairing: return "Pair this device"
        case .connecting: return "Connecting to your device"
        case .failed: return "Connection needs attention"
        case .idle: return hasSavedPairing ? "Your pairing is saved" : "Set up native installs"
        }
    }

    private var overviewDetail: String {
        switch manager.phase {
        case .ready: return "Your device connection is ready for installation."
        case .configured: return "Setup complete. Ksign reconnects automatically when you install apps."
        case .pairing: return "Follow the steps below to approve pairing in Settings."
        case .connecting: return "Ksign is preparing its local VPN and device connection."
        case .failed: return "Review the message below, then try the connection again."
        case .idle:
            return hasSavedPairing
                ? "Ksign will connect when you install. You can check the connection now with Setup."
                : "Pair your device and let Ksign handle the local VPN. Start with Setup below."
        }
    }

    private var actions: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            Button {
                Task { await manager.setUp() }
            } label: {
                ConnectionAction(title: "Setup", detail: "Pair & check connection", symbol: "bolt.fill")
            }
            .disabled(controlsDisabled)
            .opacity(controlsDisabled ? 0.5 : 1)

            NavigationLink {
                VPNReconnectPreferencesView()
            } label: {
                ConnectionAction(title: "Restore VPN", detail: "Reconnect after installs", symbol: "arrow.triangle.2.circlepath")
            }

            Button { showsGuide = true } label: {
                ConnectionAction(title: "Pairing guide", detail: "A few simple steps", symbol: "lightbulb")
            }

            Button(role: .destructive) { confirmReset = true } label: {
                ConnectionAction(title: "Forget pairing", detail: "Remove saved pairing", symbol: "trash", role: .danger)
            }
            .disabled(controlsDisabled)
            .opacity(controlsDisabled ? 0.5 : 1)
        }
    }

    private var connectionStatus: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 16) {
                    pairingStatus
                    sessionStatus
                }
            } else {
                HStack(alignment: .top, spacing: 20) {
                    pairingStatus
                    Divider()
                    sessionStatus
                }
            }
        }
        .connectionCard()
    }

    private var pairingStatus: some View {
        statusItem("Built-in pairing", detail: hasSavedPairing ? "Saved on this device" : "Not saved", symbol: "link",
                   role: hasSavedPairing ? .success : .textSecondary)
    }

    private var sessionStatus: some View {
        // Ready describes the manager's device session. The VPN can be torn down
        // or change independently, so do not present this as live VPN telemetry.
        statusItem("Device session", detail: sessionDetail, symbol: "iphone",
                   role: manager.phase == .ready ? .success : .textSecondary)
    }

    private var sessionDetail: String {
        switch manager.phase {
        case .ready: return "Connected"
        case .connecting: return "Connecting"
        case .pairing: return "Pairing"
        case .failed: return "Needs attention"
        case .idle, .configured: return "On demand"
        }
    }

    private func statusItem(_ title: String, detail: String, symbol: String, role: NBThemeRole) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).nbThemeForeground(role)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption).nbThemeForeground(.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func refreshPairingStatus() {
        hasSavedPairing = (try? DevicePairingStore.load()) != nil
    }
}

private struct ConnectionIcon: View {
    let symbol: String
    var role: NBThemeRole = .accent

    var body: some View {
        Image(systemName: symbol)
            .font(.title3.weight(.semibold))
            .nbThemeForeground(role)
            .frame(width: 46, height: 46)
            .nbThemeBackground(role, opacity: 0.13, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityHidden(true)
    }
}

private struct ConnectionAction: View {
    let title: String
    let detail: String
    let symbol: String
    var role: NBThemeRole = .accent

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ConnectionIcon(symbol: symbol, role: role)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).nbThemeForeground(role == .danger ? .danger : .text)
                Text(detail).font(.caption).nbThemeForeground(.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
        .connectionCard()
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    func connectionCard(highlighted: Bool = false) -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nbThemeBackground(.elevated, in: RoundedRectangle(cornerRadius: 22))
            .nbThemeOverlay {
                RoundedRectangle(cornerRadius: 22)
                    .nbThemeStrokeBorder(highlighted ? .accent : .border, opacity: highlighted ? 0.45 : 0.55, lineWidth: 1)
            }
    }
}

private struct DeviceUploadPerformanceView: View {
    @AppStorage(IDeviceUploadMetrics.storageKey) private var lastUpload = Data()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Latest upload", systemImage: "arrow.up.doc")
                .font(.subheadline.weight(.semibold))
            if let metrics = try? JSONDecoder().decode(IDeviceUploadMetrics.self, from: lastUpload) {
                Text(metrics.summary)
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text("Upload time & average speed, excluding connection setup and iOS installation.")
                    .font(.caption)
                    .nbThemeForeground(.textSecondary)
            } else {
                Text("No uploads yet")
                    .font(.subheadline)
                    .nbThemeForeground(.textSecondary)
                Text("Upload time and speed will appear after your first native upload completes.")
                    .font(.caption)
                    .nbThemeForeground(.textSecondary)
            }
        }
        .connectionCard()
    }
}

private struct VPNReconnectPreferencesView: View {
    @AppStorage(VPNReconnectCoordinator.enabledKey) private var enabled = false
    @AppStorage(VPNReconnectCoordinator.shortcutNameKey) private var shortcutName = VPNReconnectCoordinator.defaultShortcutName
    @AppStorage(VPNReconnectCoordinator.presentationKey) private var presentation = VPNReconnectPresentation.shareSheet.rawValue
    @ObservedObject private var reconnect = VPNReconnectCoordinator.shared
    @ObservedObject private var manager = DeviceInstallationManager.shared
    private let session = InstallSession.shared
    @State private var isSessionActive = InstallSession.shared.isActive

    private var canTest: Bool {
        manager.canReconnectVPN && !isSessionActive &&
            !shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NBList("Restore VPN") {
            Section {
                Toggle("Reconnect after installation", isOn: $enabled)
            } footer: {
                Text("Ksign offers to reconnect your VPN after all device work ends and its local VPN disconnects. If installation finishes in the background, tap the reconnect notification.")
            }
            if enabled {
                Section {
                    TextField("Shortcut name", text: $shortcutName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Shortcut name")
                    Picker("Reconnect method", selection: $presentation) {
                        ForEach(VPNReconnectPresentation.allCases) { method in
                            Text(method.title).tag(method.rawValue)
                        }
                    }
                } header: {
                    Text("Your shortcut")
                } footer: {
                    Text("Create a shortcut that connects your VPN and enter its exact name. The default is Restore Tailscale, using Tailscale's Connect action.")
                }
                Section {
                    if presentation == VPNReconnectPresentation.shareSheet.rawValue {
                        Text("In your shortcut's details, enable Show in Share Sheet and allow Text input. Select it from Ksign's share sheet to reconnect. Remove Open App actions to stay in Ksign.")
                        Text("If you dismiss the sheet, tap the Reconnect VPN reminder to open it again.")
                    } else {
                        Text("Ksign opens Shortcuts automatically. Add Open App → Ksign as the shortcut's last action to return here.")
                    }
                } header: {
                    Text("How to reconnect")
                }
                Section {
                    Button(presentation == VPNReconnectPresentation.shareSheet.rawValue ? "Test Share Sheet" : "Test Reconnect Shortcut") {
                        Task { await manager.testVPNReconnectShortcut() }
                    }
                    .disabled(!canTest)
                    if reconnect.pendingShortcutName != nil {
                        Button("Reconnect VPN") { Task { await reconnect.runPendingShortcut() } }
                            .disabled(!manager.canReconnectVPN || isSessionActive)
                    }
                    if let notice = reconnect.notice {
                        Text(notice).font(.footnote).nbThemeForeground(.textSecondary)
                    }
                }
            }
        }
        .buttonStyle(.automatic)
        .onReceive(session.isActivePublisher) { isSessionActive = $0 }
        .onChange(of: enabled) { enabled in
            if enabled { Task { await reconnect.requestNotificationPermission() } }
            else { reconnect.disable() }
        }
    }
}

struct DeviceConnectionSetupView: View {
    @ObservedObject private var manager = DeviceInstallationManager.shared
    @ObservedObject private var pairing = DevicePairingService.shared
    private let session = InstallSession.shared
    @State private var isSessionActive = InstallSession.shared.isActive
    var alwaysVisible = false
    var failureInstructions = "Once connected, retry failed apps in the install drawer."

    var body: some View {
        Group {
            if alwaysVisible || manager.showsSetup {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Device setup", systemImage: "iphone.and.arrow.forward")
                        .font(.headline)
                    if let notice = manager.setupNotice {
                        Text(notice).font(.callout).nbThemeForeground(.textSecondary)
                    }
                    switch manager.phase {
                    case .pairing:
                        DevicePairingInstructions(isPairing: true)
                        if let pin = pairing.pin {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("YOUR PAIRING CODE")
                                    .font(.caption2.weight(.bold))
                                    .tracking(1.2)
                                    .nbThemeForeground(.textSecondary)
                                Text(pin)
                                    .font(.system(.largeTitle, design: .monospaced).bold())
                                    .textSelection(.enabled)
                                    .accessibilityLabel("Pairing code")
                                    .accessibilityValue(pin.map { String($0) }.joined(separator: " "))
                                Text("Enter this code in Settings, then return to Ksign. It also appears in the system progress activity when available.")
                                    .font(.caption)
                                    .nbThemeForeground(.textSecondary)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .nbThemeBackground(.controlFill, in: RoundedRectangle(cornerRadius: 16))
                        } else {
                            ProgressView("Waiting for Pair with Ksign…")
                                .font(.subheadline)
                        }
                        cancelButton
                    case .connecting:
                        ProgressView("Preparing your connection…")
                        Text("Allow Ksign to add its VPN configuration if iOS asks.")
                            .font(.subheadline)
                            .nbThemeForeground(.textSecondary)
                        cancelButton
                    case .failed(let message):
                        Label("Couldn't finish setup", systemImage: "exclamationmark.triangle")
                            .font(.subheadline.weight(.semibold))
                            .nbThemeForeground(.danger)
                        Text(message).font(.callout).textSelection(.enabled)
                        Button("Retry Setup") { Task { await manager.setUp() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(manager.isBusy)
                        Text(failureInstructions)
                            .font(.caption)
                            .nbThemeForeground(.textSecondary)
                    case .ready:
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .nbThemeForeground(.success)
                    case .configured:
                        Label("Setup complete", systemImage: "checkmark.circle.fill")
                            .nbThemeForeground(.success)
                        Text("Ksign reconnects automatically when you install apps.")
                            .font(.subheadline)
                            .nbThemeForeground(.textSecondary)
                    case .idle:
                        Text("Pair your device and configure the local VPN to get started.")
                            .font(.subheadline)
                            .nbThemeForeground(.textSecondary)
                        Button("Set Up Connection") { Task { await manager.setUp() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(manager.isBusy || isSessionActive)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .nbThemeForeground(.text)
            }
        }
        .onReceive(session.isActivePublisher) { isSessionActive = $0 }
    }

    private var cancelButton: some View {
        Button("Cancel Setup", role: .cancel) { manager.cancelSetup() }
            .buttonStyle(.bordered)
    }
}

private struct DevicePairingInstructions: View {
    var isPairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            step(1, title: isPairing ? "Allow access" : "Start in Ksign",
                 detail: isPairing
                    ? "Allow Local Network access if asked so Settings can find Ksign."
                    : "Tap Setup and allow Local Network access and the VPN configuration when asked.")
            step(2, title: "Approve in Settings", detail: "Open Settings → Privacy & Security → Developer Mode. Enable it if needed, then choose Pair with Ksign.")
            step(3, title: "Enter your pairing code", detail: "Use the code shown in Ksign, then return here to finish connecting.")
        }
    }

    private func step(_ number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .nbThemeForeground(.accent)
                .frame(width: 28, height: 28)
                .nbThemeBackground(.accent, opacity: 0.12, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).nbThemeForeground(.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

import SwiftUI
import NimbleViews

struct InstallationMethodMenu: View {
    @AppStorage("Feather.installationMethod") private var method = 0
    @ObservedObject private var manager = DeviceInstallationManager.shared
    @State private var isSessionActive = InstallSession.shared.isActive

    private var isNative: Bool { method == 1 }

    var body: some View {
        Menu {
            Picker("Installation method", selection: $method) {
                Label("Native", systemImage: "iphone").tag(1)
                Label("Server", systemImage: "server.rack").tag(0)
            }
        } label: {
            NBButton("Installation method", systemImage: isNative ? "iphone" : "server.rack")
                .frame(minWidth: 32, minHeight: 32)
        }
        .accessibilityLabel("Installation method")
        .accessibilityValue(isNative ? Text("Native") : Text("Server"))
        .disabled(manager.isBusy || isSessionActive)
        .onReceive(InstallSession.shared.isActivePublisher) { isSessionActive = $0 }
    }
}

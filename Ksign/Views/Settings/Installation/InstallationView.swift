//
//  InstallationView.swift
//  Feather
//
//  Created by samara on 3.06.2025.
//

import SwiftUI
import NimbleExtensions
import NimbleViews

// MARK: - View
struct InstallationView: View {
    @AppStorage("Feather.installationMethod") private var _installationMethod: Int = 0

    private let _installationMethods: [String] = [
        .localized("Server"),
        .localized("idevice")
    ]
    
    // MARK: Body
    var body: some View {
        NBList(.localized("Installation")) {
            Section {
                Picker(.localized("Installation Type"), systemImage: "arrow.down.app", selection: $_installationMethod) {
                    ForEach(_installationMethods.indices, id: \.description) { index in
                        Text(_installationMethods[index]).tag(index)
                    }
                }
            } footer: {
                Text("Server uses a local web server to install apps. iDevice installs directly through this device's installation service, with progress for each app. Choose Built-in Connection to let Ksign manage pairing and its local VPN.")
                .nbThemeForeground(.textSecondary)
            }
            
            if _installationMethod == 0 {
                ServerView()
            } else if _installationMethod == 1 {
                DeviceConnectionSettingsView()
            }
        }
        .animation(.default, value: _installationMethod)
    }
}


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
    @ObservedObject private var manager = DeviceInstallationManager.shared
    private let session = InstallSession.shared
    @State private var isSessionActive = InstallSession.shared.isActive
    
    // MARK: Body
    var body: some View {
        Group {
            if _installationMethod == 1 {
                ScrollView {
                    VStack(spacing: 16) {
                        methodPicker
                            .padding(18)
                            .nbThemeBackground(.elevated, in: RoundedRectangle(cornerRadius: 22))
                        DeviceConnectionSettingsView()
                    }
                    .padding(20)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                }
            } else {
                NBList(.localized("Installation")) {
                    Section { methodPicker }
                    ServerView()
                }
            }
        }
        .nbThemeCanvas()
        .onReceive(session.isActivePublisher) { isSessionActive = $0 }
        .navigationTitle(.localized("Installation"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var methodPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Install apps with", systemImage: "arrow.down.app")
                .font(.subheadline.weight(.semibold))
            Picker("Installation method", selection: $_installationMethod) {
                Text("Server").tag(0)
                Text("Native · iDevice").tag(1)
            }
            .pickerStyle(.segmented)
            .disabled(manager.isBusy || isSessionActive)
            Text(_installationMethod == 0
                 ? "Install through a local web server."
                 : "Install directly on this device, with progress for every app.")
                .font(.caption)
                .nbThemeForeground(.textSecondary)
        }
    }
}


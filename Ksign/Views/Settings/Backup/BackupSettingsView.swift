import SwiftUI
import UniformTypeIdentifiers
import NimbleViews
import NimbleExtensions

extension UTType {
    static let asignBackup = UTType(exportedAs: "app.asign.settings-backup", conformingTo: .data)
}

struct BackupSettingsView: View {
    @ObservedObject private var deviceManager = DeviceInstallationManager.shared
    @State private var password = ""
    @State private var passwordConfirmation = ""
    @State private var restorePassword = ""
    @State private var busy = false
    @State private var importing = false
    @State private var exporting = false
    @State private var exportURL: URL?
    @State private var encryptedBackup: Data?
    @State private var reviewedBackup: SettingsBackup?
    @State private var restoreConfirmation = false
    @State private var message: String?
    @State private var failure: String?

    private var canRestore: Bool {
        !busy && deviceManager.canReconnectVPN && !InstallSession.shared.isActive
    }

    var body: some View {
        NBList("Backup & Restore") {
            introductionSection
            createSection
            restoreSection
            statusSections
        }
        .navigationTitle("Backup & Restore")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.asignBackup, .data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { loadBackup(url) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { failure = error.localizedDescription }
            }
        }
        .sheet(isPresented: $exporting, onDismiss: clearExport) {
            if let exportURL {
                FileExporterRepresentableView(urlsToExport: [exportURL], asCopy: true, useLastLocation: true, onCompletion: { saved in
                    if saved { message = "Backup saved. Keep it outside ASign so it survives deleting the app." }
                    exporting = false
                })
            }
        }
        .confirmationDialog("Restore saved themes and settings?", isPresented: $restoreConfirmation, titleVisibility: .visible) {
            Button("Restore Backup") { restoreBackup() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This applies the backup's settings and themes and adds its certificates and sources.")
        }
        .alert("Backup & Restore", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
        .onDisappear {
            password = ""
            passwordConfirmation = ""
            restorePassword = ""
        }
    }

    private var introductionSection: some View {
        Section {
            Text("Save your certificates, certificate passwords, custom themes, settings, and source subscriptions in one password-protected file.")
            Text("App libraries, archives, tweak files, and device pairing are not included.")
                .font(.footnote).nbThemeForeground(.textSecondary)
        }
    }

    private var createSection: some View {
        Section {
            SecureField("Backup password", text: $password)
                .textContentType(.newPassword)
            SecureField("Confirm password", text: $passwordConfirmation)
                .textContentType(.newPassword)
            Button("Create Backup") { createBackup() }
                .disabled(busy || password.count < 8 || password != passwordConfirmation)
        } header: {
            Text("Create Backup")
        } footer: {
            Text("Use at least 8 characters. Save the file to iCloud Drive or another folder outside ASign before deleting the app. You will need this password to restore it.")
        }
    }

    private var restoreSection: some View {
        Section {
            Button("Choose Backup File") { importing = true }
                .disabled(busy)
            if encryptedBackup != nil && reviewedBackup == nil {
                SecureField("Backup password", text: $restorePassword)
                Button("Unlock Backup") { unlockBackup() }
                    .disabled(busy || restorePassword.isEmpty)
            }
            if let backup = reviewedBackup {
                Text("Created \(backup.createdAt.formatted(date: .abbreviated, time: .shortened))")
                Text("\(backup.certificates.count) certificates and \(backup.sources.count) source subscriptions, plus themes and settings.")
                Button("Restore Backup") { restoreConfirmation = true }
                    .disabled(!canRestore)
            }
        } header: {
            Text("Restore Backup")
        } footer: {
            Text("Restore adds certificates and sources and applies the saved themes and settings. Existing apps remain in your library. Finish installations before restoring. Pair this device again if needed.")
        }
    }

    @ViewBuilder private var statusSections: some View {
        if busy { Section { ProgressView("Working…") } }
        if let message { Section { Text(message).nbThemeForeground(.success) } }
    }

    private func createBackup() {
        guard !busy else { return }
        busy = true
        message = nil
        let secret = password
        Task { @MainActor in
            defer { busy = false }
            do {
                let backup = try SettingsBackupService.snapshot()
                let url = try await Task.detached(priority: .userInitiated) {
                    let data = try SettingsBackupCrypto.encrypt(backup, password: secret)
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ASign-Backup-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent("ASign-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")).asignbackup")
                    do { try data.write(to: url, options: [.atomic, .completeFileProtection]) }
                    catch { try? FileManager.default.removeItem(at: folder); throw error }
                    return url
                }.value
                exportURL = url
                password = ""
                passwordConfirmation = ""
                exporting = true
            } catch { failure = error.localizedDescription }
        }
    }

    private func clearExport() {
        if let exportURL { try? FileManager.default.removeItem(at: exportURL.deletingLastPathComponent()) }
        exportURL = nil
    }

    private func loadBackup(_ url: URL) {
        busy = true
        message = nil
        reviewedBackup = nil
        encryptedBackup = nil
        restorePassword = ""
        Task { @MainActor in
            defer { busy = false }
            do {
                encryptedBackup = try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                       size > SettingsBackup.maximumFileSize { throw BackupError.tooLarge }
                    let data = try Data(contentsOf: url)
                    guard data.count <= SettingsBackup.maximumFileSize else { throw BackupError.tooLarge }
                    return data
                }.value
            } catch { failure = error.localizedDescription }
        }
    }

    private func unlockBackup() {
        guard let data = encryptedBackup, !busy else { return }
        busy = true
        let secret = restorePassword
        Task { @MainActor in
            defer { busy = false }
            do {
                reviewedBackup = try await Task.detached(priority: .userInitiated) {
                    try SettingsBackupCrypto.decrypt(data, password: secret)
                }.value
                encryptedBackup = nil
                restorePassword = ""
            } catch { failure = error.localizedDescription }
        }
    }

    private func restoreBackup() {
        guard canRestore, let backup = reviewedBackup else { return }
        busy = true
        defer { busy = false }
        do {
            try SettingsBackupService.restore(backup)
            reviewedBackup = nil
            message = "Restored certificates, sources, themes, and settings. Your theme is active now."
        } catch { failure = error.localizedDescription }
    }
}

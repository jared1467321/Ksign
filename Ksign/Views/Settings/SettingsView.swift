//
//  SettingsView.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import NimbleExtensions
import NimbleViews

// MARK: - View
struct SettingsView: View {
    @AppStorage("feather.selectedCert") private var _storedSelectedCert: Int = 0
    @FetchRequest(
        entity: CertificatePair.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
        animation: .snappy
    ) private var _certificates: FetchedResults<CertificatePair>
    
    private var selectedCertificate: CertificatePair? {
        guard
            _storedSelectedCert >= 0,
            _storedSelectedCert < _certificates.count
        else {
            return nil
        }
        return _certificates[_storedSelectedCert]
    }
    
    
	// MARK: Body
    var body: some View {
		NBNavigationView(.localized("Settings"), displayMode: .inline, adaptsContainerText: false) {
			Form {
				// Keep Sections directly in the Form. Adaptive paint belongs on
				// labels; wrapping the section collection turns it into one row.
				Section {
                    NavigationLink(destination: AppIconView()) {
                        Label(.localized("App Icon"), systemImage: "app.badge")
                            .nbThemeForeground(.text)
                    }
                    .nbThemeRow(adaptsText: false)
					NavigationLink(destination: AppearanceView()) {
                        Label(.localized("Appearance"), systemImage: "paintbrush")
                            .nbThemeForeground(.text)
                    }
                    .nbThemeRow(adaptsText: false)
				}
                
                NBSection(.localized("Certificates")) {
                    
                    if let cert = selectedCertificate {
                        CertificatesCellView(cert: cert)
                            .nbThemeRow(adaptsText: false)
                    } else {
                        Text(.localized("No Certificate"))
                            .font(.footnote)
                            .nbThemeForeground(.disabledText)
                            .nbThemeRow(adaptsText: false)
                    }
                    NavigationLink(destination: CertificatesView()) {
                        Label(.localized("Certificates"), systemImage: "signature")
                            .nbThemeForeground(.text)
                    }
                    .nbThemeRow(adaptsText: false)
                 
                } footer: {
                    Text(.localized("Add and manage certificates used for signing applications."))
                    .nbThemeForeground(.textSecondary)
                }
				
				NBSection(.localized("Features")) {
                    NavigationLink(destination: LogsView(manager: LogsManager.shared)) {
                        Label(.localized("Logs"), systemImage: "apple.terminal")
                            .nbThemeForeground(.text)
                    }
                    .nbThemeRow(adaptsText: false)
					NavigationLink(destination: AppFeaturesView()) {
                        Label(.localized("App Features"), systemImage: "sparkles")
                            .nbThemeForeground(.text)
                    }
                    .nbThemeRow(adaptsText: false)
					NavigationLink(destination: ConfigurationView()) {
                        Label(.localized("Signing Options"), systemImage: "gear")
                            .nbThemeForeground(.text)
                    }
                    .nbThemeRow(adaptsText: false)
					NavigationLink(destination: ArchiveView()) {
                        Label(.localized("Archive & Extraction"), systemImage: "archivebox")
                            .nbThemeForeground(.text)
                    }
                    .nbThemeRow(adaptsText: false)
					NavigationLink(destination: InstallationView()) {
                        Label(.localized("Installation"), systemImage: "server.rack")
                            .nbThemeForeground(.text)
                    }
                    .nbThemeRow(adaptsText: false)
				}
				
				_directories()
                
                Section {
                    NavigationLink(destination: BackupSettingsView()) {
                        Label("Backup & Restore", systemImage: "externaldrive")
                            .nbThemeForeground(.text)
                    }
                    .nbThemeRow(adaptsText: false)
                    NavigationLink(destination: ResetView()) {
                        Label(.localized("Reset"), systemImage: "trash")
                            .nbThemeForeground(.text)
                    }
                    .nbThemeRow(adaptsText: false)
                } footer: {
                    Text("Reset the applications sources, certificates, apps, and general contents.")
                    .nbThemeForeground(.textSecondary)
                }

			}
            .nbThemeCanvas(rendersAurora: false, adaptsText: false)
            .nbThemeTextViewport()
        }
    }
}

// MARK: - View extension
extension SettingsView {
	@ViewBuilder
	private func _directories() -> some View {
		NBSection(.localized("Misc")) {
			Button {
				UIApplication.open(URL.documentsDirectory.toSharedDocumentsURL()!)
			} label: {
				Label(.localized("Open Documents"), systemImage: "folder")
					.nbThemeForeground(.text)
			}
			.nbThemeRow(adaptsText: false)
			Button {
				UIApplication.open(FileManager.default.archives.toSharedDocumentsURL()!)
			} label: {
				Label(.localized("Open Archives"), systemImage: "folder")
					.nbThemeForeground(.text)
			}
			.nbThemeRow(adaptsText: false)
		} footer: {
			Text(.localized("All of Ksign files except certificates are contained in the documents directory, here are some quick links to these."))
			.nbThemeForeground(.textSecondary)
		}
	}
}

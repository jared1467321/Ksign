//
//  InstallPreview.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import SwiftUI
import Combine
import NimbleViews
import IDeviceSwift
import OSLog

// MARK: - View
struct InstallPreviewView: View {
	@Environment(\.dismiss) var dismiss
	
	// Sharing
	@AppStorage("Feather.useShareSheetForArchiving") private var _useShareSheet: Bool = false
	
	// Methods
    @AppStorage("Feather.installationMethod") private var _installationMethod: Int = 0
	@AppStorage("Feather.serverMethod") private var _serverMethod: Int = 0
	@State private var _isWebviewPresenting = false
    @State private var progressTask: Task<Void, Never>?
	// Where ArchiveHandler staged this install's .ipa. Nothing deleted it
	// before, so every single-app install left a full-size archive in tmp
	// until the next cold start.
	@State private var _archiveWorkDir: URL?
	
	var app: AppInfoPresentable
	@StateObject var viewModel: InstallerStatusViewModel
	@StateObject var installer: ServerInstaller
	@State var isSharing: Bool

	init(app: AppInfoPresentable, isSharing: Bool = false) {
		self.app = app
		self.isSharing = isSharing
        let method = UserDefaults.standard.integer(forKey: "Feather.installationMethod")
		let viewModel = InstallerStatusViewModel(isIdevice: method == 1)
		self._viewModel = StateObject(wrappedValue: viewModel)
		self._installer = StateObject(wrappedValue: try! ServerInstaller(app: app, viewModel: viewModel))
	}
	
	// MARK: Body
	var body: some View {
		ZStack {
			InstallProgressView(app: app, viewModel: viewModel)
			_status()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
		.sheet(isPresented: $_isWebviewPresenting) {
			SafariRepresentableView(url: installer.pageEndpoint).ignoresSafeArea()
		}
		.onReceive(viewModel.$status) { newStatus in
			if #available(iOS 16.2, *) {
				KeepAliveActivityController.shared.report(.singleInstall, detail: viewModel.statusLabel)
			}

			if case .ready = newStatus {
				if _serverMethod == 0 {
					UIApplication.shared.open(URL(string: installer.iTunesLink)!)
				} else if _serverMethod == 1 {
					_isWebviewPresenting = true
				}
			}
            
            // Server method only — idevice reports progress via its own callback.
            if case .installing = newStatus, _installationMethod == 0 {
                if progressTask == nil {
                    progressTask = startInstallProgressPolling(
                        bundleID: app.identifier!,
                        viewModel: viewModel
                    )
                }
            }
			
			if case .sendingPayload = newStatus, _serverMethod == 1 {
				_isWebviewPresenting = false
			}
            
            switch newStatus {
            case .completed, .broken(_):
                progressTask?.cancel()
                progressTask = nil
                if #available(iOS 16.2, *) {
                    if case .completed = newStatus {
                        KeepAliveActivityController.shared.report(.singleInstall, fraction: 1)
                        KeepAliveActivityController.shared.report(.singleInstall, completed: 1, total: 1)
                    }
                    // Leave "Completed" or "Error" visible during the audio
                    // manager's linger window. onDisappear withdraws the report.
                }
                BackgroundAudioManager.shared.release(.singleInstall)
                _cleanupArchive()
            default:
                break
            }
		}
		.onReceive(viewModel.$installProgress.removeDuplicates()) { progress in
			guard #available(iOS 16.2, *) else { return }
			KeepAliveActivityController.shared.report(.singleInstall, fraction: progress)
		}
		.onAppear(perform: _install)
		.onAppear {
			BackgroundAudioManager.shared.claim(.singleInstall)

			if #available(iOS 16.2, *) {
				KeepAliveActivityController.shared.report(.singleInstall, completed: 0, total: 1)
				KeepAliveActivityController.shared.report(.singleInstall, fraction: 0)
			}
		}
		.onDisappear {
            progressTask?.cancel()
            progressTask = nil

			if #available(iOS 16.2, *) {
				KeepAliveActivityController.shared.clearReport(.singleInstall)
			}

			BackgroundAudioManager.shared.release(.singleInstall)
			// Covers dismissal before a terminal status ever arrives.
			_cleanupArchive()
		}
	}
	
	// Idempotent — dismissal and the terminal status both land here, and
	// whichever arrives first wins.
	private func _cleanupArchive() {
		guard let dir = _archiveWorkDir else { return }
		_archiveWorkDir = nil
		installer.packageUrl = nil
		ArchiveHandler.cleanup(workDir: dir)
	}
	
	@ViewBuilder
	private func _status() -> some View {
		Label(viewModel.statusLabel, systemImage: viewModel.statusImage)
			.padding()
			.labelStyle(.titleAndIcon)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
			.animation(.smooth, value: viewModel.statusImage)
	}
	
	private func _install() {
        guard isSharing || app.identifier != Bundle.main.bundleIdentifier! || _installationMethod == 1 else {
            UIAlertController.showAlertWithOk(
                title: .localized("Install"),
                message: .localized("You cannot update ‘%@‘ with itself, please use an alternative tool to update it.", arguments: Bundle.main.name)
            )
            return
        }

		Task.detached {
			do {
				let handler = await ArchiveHandler(app: app, viewModel: viewModel)
				try await handler.move()
				
				let workDir = await handler.workDir
				let packageUrl = try await handler.archive()
				
				await MainActor.run {
					_archiveWorkDir = workDir
				}
				
				if await !isSharing {
                    if await _installationMethod == 0 {
                        await MainActor.run {
                            installer.packageUrl = packageUrl
                            viewModel.status = .ready
                        }
                        
                        if case .installing = await viewModel.status {
                            let task = await startInstallProgressPolling(
                                bundleID: app.identifier!,
                                viewModel: viewModel
                            )

                            await MainActor.run {
                                progressTask = task
                            }
                        }
                    }
                    else if await _installationMethod == 1 {
                        let handler = await InstallationProxy(viewModel: viewModel)
                        try await handler.install(at: packageUrl, suspend: app.identifier == Bundle.main.bundleIdentifier!)
                    }
				} else {
					let package = try await handler.moveToArchive(packageUrl, shouldOpen: !_useShareSheet)
					
					if await !_useShareSheet {
						await MainActor.run {
							dismiss()
						}
					} else {
						if let package {
							await MainActor.run {
								dismiss()
								UIActivityViewController.show(activityItems: [package])
							}
						}
					}
				}
			} catch {
                await progressTask?.cancel()
				await MainActor.run {
					UIAlertController.showAlertWithOk(
						title: .localized("Install"),
						message: error.localizedDescription,
						action: {
							HeartbeatManager.shared.start(true)
							dismiss()
						}
					)
				}
			}
		}
	}

    private func startInstallProgressPolling(
            bundleID: String,
            viewModel: InstallerStatusViewModel
        ) -> Task<Void, Never> {

            Task.detached(priority: .userInitiated) {
                var hasStarted = false
                let startedAt = Date()

                while !Task.isCancelled {
                    // nil means no install is currently registered for this bundle;
                    // zero means an install exists but has not advanced yet.
                    let rawProgress = await UIApplication.installProgress(for: bundleID)

                    if let rawProgress, rawProgress > 0 {
                        hasStarted = true
                    }

                    let progress = hasStarted
                        ? Self._normalizeInstallProgress(rawProgress ?? 0)
                        : 0.0

                    await MainActor.run {
                        viewModel.installProgress = progress
                    }

                    // Normal completion is the falling edge from a visible install
                    // to no registered install. The presence check catches an install
                    // that completed entirely between two samples.
                    let finishedByEdge = hasStarted && rawProgress == nil
                    let finishedByPresence = !hasStarted
                        && rawProgress == nil
                        && Date().timeIntervalSince(startedAt) > 8
                        && UIApplication.isAppInstalled(bundleID)

                    if finishedByEdge || finishedByPresence {
                        await MainActor.run {
                            viewModel.installProgress = 1.0
                            viewModel.status = .completed(.success(()))
                        }
                        break
                    }

                    try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
                }
            }
        }

        private static func _normalizeInstallProgress(_ rawProgress: Double) -> Double {
            min(1.0, max(0.0, (rawProgress - 0.6) / 0.3))
        }
}

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
	@State private var _activityCancellables = Set<AnyCancellable>()
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
		self._installer = StateObject(
			wrappedValue: try! ServerInstaller(
				app: app,
				viewModel: viewModel,
				statusReporter: { status in
					SingleInstallLiveActivityReporter.shared.updateStatus(status)
				}
			)
		)
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
			if case .ready = newStatus {
				if _serverMethod == 0 {
					UIApplication.shared.open(URL(string: installer.iTunesLink)!)
				} else if _serverMethod == 1 {
					_isWebviewPresenting = true
				}
			}

			// Server method only — idevice reports progress via its own callback.
			if case .installing = newStatus, _installationMethod == 0, progressTask == nil {
				progressTask = startInstallProgressPolling(
					bundleID: app.identifier!,
					viewModel: viewModel
				)
			}

			if case .sendingPayload = newStatus, _serverMethod == 1 {
				_isWebviewPresenting = false
			}

			switch newStatus {
			case .completed, .broken(_):
				progressTask?.cancel()
				progressTask = nil
				BackgroundAudioManager.shared.release(.singleInstall)
				_cleanupArchive()
			default:
				break
			}
		}
		.onAppear {
			BackgroundAudioManager.shared.claim(.singleInstall)
			SingleInstallLiveActivityReporter.shared.begin()
			_startLiveActivityBridge()
			_install()
		}
		.onDisappear {
			progressTask?.cancel()
			progressTask = nil
			_activityCancellables.removeAll()
			SingleInstallLiveActivityReporter.shared.end()
			BackgroundAudioManager.shared.release(.singleInstall)
			// Covers dismissal before a terminal status ever arrives.
			_cleanupArchive()
		}
	}
	
	// These Combine subscriptions are owned by the install, not by a SwiftUI
	// rendering pass. They receive idevice progress as well as server-method
	// progress and forward only primitive values to the background-safe mirror.
	private func _startLiveActivityBridge() {
		_activityCancellables.removeAll()

		viewModel.$status
			.sink { status in
				SingleInstallLiveActivityReporter.shared.updateStatus(status)
			}
			.store(in: &_activityCancellables)

		viewModel.$packageProgress
			.removeDuplicates()
			.sink { progress in
				SingleInstallLiveActivityReporter.shared.updatePackage(progress)
			}
			.store(in: &_activityCancellables)

		viewModel.$installProgress
			.removeDuplicates()
			.sink { progress in
				SingleInstallLiveActivityReporter.shared.updateInstall(progress)
			}
			.store(in: &_activityCancellables)
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
				let handler = await ArchiveHandler(
					app: app,
					viewModel: viewModel,
					progressReporter: { progress in
						SingleInstallLiveActivityReporter.shared.updatePackage(progress)
					}
				)
				try await handler.move()
				
				let workDir = await handler.workDir
				let packageUrl = try await handler.archive()
				
				await MainActor.run {
					_archiveWorkDir = workDir
				}
				
				if await !isSharing {
                    if await _installationMethod == 0 {
                        SingleInstallLiveActivityReporter.shared.updateStatus(.ready)
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
				SingleInstallLiveActivityReporter.shared.updateStatus(.broken(error))
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

                    SingleInstallLiveActivityReporter.shared.updateInstall(progress)
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
                        SingleInstallLiveActivityReporter.shared.finish()
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

// MARK: - Background-safe single-install Live Activity mirror

// The view model remains UI-oriented, but the archiver, local server and
// install-progress poller all have worker-thread callbacks. Mirroring those
// primitive values here prevents the Live Activity from waiting for SwiftUI's
// onReceive handlers to run after the app returns to the foreground.
final class SingleInstallLiveActivityReporter {
	static let shared = SingleInstallLiveActivityReporter()

	private let _queue = DispatchQueue(
		label: "nya.asami.ksign.single-install-live-activity",
		qos: .userInitiated
	)

	private var _active = false
	private var _packageProgress: Double = 0
	private var _installProgress: Double = 0
	private var _detail = "Packaging"
	private var _completed = false

	private init() { }

	func begin() {
		_queue.async {
			self._active = true
			self._packageProgress = 0
			self._installProgress = 0
			self._detail = "Packaging"
			self._completed = false

			guard #available(iOS 16.2, *) else { return }
			KeepAliveActivityController.shared.clearReport(.singleInstall)
			self._publish()
		}
	}

	func updatePackage(_ progress: Double) {
		_queue.async {
			guard self._active, !self._completed else { return }
			self._packageProgress = max(
				self._packageProgress,
				min(1, max(0, progress))
			)
			self._detail = "Packaging"
			self._publish()
		}
	}

	func updateInstall(_ progress: Double) {
		_queue.async {
			guard self._active, !self._completed else { return }
			let clamped = min(1, max(0, progress))

			// Ignore the @Published property's initial zero. A real install update
			// either follows the Installing status or has moved above zero.
			guard clamped > 0 || self._detail == "Installing" else { return }

			self._packageProgress = 1
			self._installProgress = max(self._installProgress, clamped)
			self._detail = "Installing"
			self._publish()
		}
	}

	func updateStatus(_ status: InstallerStatusViewModel.InstallerStatus) {
		let change: (detail: String, packageFinished: Bool, completed: Bool)

		switch status {
		case .none:
			change = ("Packaging", false, false)
		case .ready:
			change = ("Waiting for Confirmation", true, false)
		case .sendingManifest:
			change = ("Sending Manifest", true, false)
		case .sendingPayload:
			change = ("Sending Payload", true, false)
		case .installing:
			change = ("Installing", true, false)
		case .completed:
			change = ("Completed", true, true)
		case .broken:
			change = ("Error", false, false)
		}

		_queue.async {
			guard self._active else { return }
			self._detail = change.detail
			if change.packageFinished { self._packageProgress = 1 }
			if change.completed {
				self._packageProgress = 1
				self._installProgress = 1
				self._completed = true
			}
			self._publish()
		}
	}

	func finish() {
		_queue.async {
			guard self._active else { return }
			self._packageProgress = 1
			self._installProgress = 1
			self._detail = "Completed"
			self._completed = true
			self._publish()
		}
	}

	func end() {
		_queue.async {
			guard self._active else { return }
			self._active = false

			if #available(iOS 16.2, *) {
				KeepAliveActivityController.shared.clearReport(.singleInstall)
			}
		}
	}

	private func _publish() {
		guard #available(iOS 16.2, *) else { return }

		let fraction = _completed
			? 1
			: min(0.99, _packageProgress * 0.45 + _installProgress * 0.55)

		KeepAliveActivityController.shared.report(.singleInstall, completed: _completed ? 1 : 0, total: 1)
		KeepAliveActivityController.shared.report(.singleInstall, fraction: fraction)
		KeepAliveActivityController.shared.report(.singleInstall, detail: _detail)
	}
}

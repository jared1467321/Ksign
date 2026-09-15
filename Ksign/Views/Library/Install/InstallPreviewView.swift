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
		let bundleID = app.identifier
		self._installer = StateObject(
			wrappedValue: try! ServerInstaller(
				app: app,
				viewModel: viewModel,
				statusReporter: { status in
					SingleInstallLiveActivityReporter.shared.handleServerStatus(
						status,
						bundleID: bundleID,
						viewModel: viewModel,
						isServerInstall: method == 0
					)
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

			if case .sendingPayload = newStatus, _serverMethod == 1 {
				_isWebviewPresenting = false
			}

			switch newStatus {
			case .completed, .broken(_):
				BackgroundAudioManager.shared.release(.singleInstall)
				_cleanupArchive()
			default:
				break
			}
		}
		.onAppear {
			SingleInstallLiveActivityReporter.shared.begin()
			BackgroundAudioManager.shared.claim(.singleInstall)
			_startLiveActivityBridge()
			_install()
		}
		.onDisappear {
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
	private var _completed = false
	private var _failed = false
	private let _serverMonitorID = UUID()

	private init() { }

	func begin() {
		_queue.sync {
			self._active = true
			self._completed = false
			self._failed = false

			guard #available(iOS 16.2, *) else { return }
			KeepAliveActivityController.shared.clearReport(.singleInstall)
			self._publish()
		}
	}

	// Keep the detailed foreground progress exactly where it already lives. The
	// Live Activity only consumes the terminal 0/1 event, avoiding hundreds of
	// ActivityKit writes during packaging/install polling.
	func updatePackage(_ progress: Double) { }
	func updateInstall(_ progress: Double) { }

	func handleServerStatus(
		_ status: InstallerStatusViewModel.InstallerStatus,
		bundleID: String?,
		viewModel: InstallerStatusViewModel,
		isServerInstall: Bool
	) {
		updateStatus(status)
		guard isServerInstall else { return }

		switch status {
		case .installing:
			guard let bundleID else { return }
			ServerInstallProgressMonitor.shared.start(
				id: _serverMonitorID,
				bundleID: bundleID,
				onProgress: { progress in
					DispatchQueue.main.async {
						viewModel.installProgress = progress
					}
				},
				onCompleted: {
					let completed = InstallerStatusViewModel.InstallerStatus.completed(.success(()))
					SingleInstallLiveActivityReporter.shared.updateStatus(completed)
					DispatchQueue.main.async {
						viewModel.installProgress = 1
						viewModel.status = completed
					}
				}
			)

		case .completed, .broken:
			ServerInstallProgressMonitor.shared.stop(id: _serverMonitorID)

		default:
			break
		}
	}

	func updateStatus(_ status: InstallerStatusViewModel.InstallerStatus) {
		_queue.async {
			guard self._active else { return }

			switch status {
			case .completed:
				self._completed = true
				self._failed = false
				self._publish()

			case .broken:
				self._completed = false
				self._failed = true
				self._publish()

			default:
				// A retry can move the install out of a prior error state.
				if self._failed {
					self._failed = false
					self._publish()
				}
			}
		}
	}

	func finish() {
		_queue.async {
			guard self._active else { return }
			self._completed = true
			self._failed = false
			self._publish()
		}
	}

	func end() {
		ServerInstallProgressMonitor.shared.stop(id: _serverMonitorID)

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

		KeepAliveActivityController.shared.report(
			.singleInstall,
			completed: _completed ? 1 : 0,
			total: 1
		)
		KeepAliveActivityController.shared.report(.singleInstall, fraction: nil)
		KeepAliveActivityController.shared.report(
			.singleInstall,
			detail: _failed ? "Error" : (_completed ? "Completed" : "Installing")
		)
	}
}

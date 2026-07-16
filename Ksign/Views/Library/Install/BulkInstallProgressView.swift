//
//  BulkInstallProgressView.swift
//  Ksign
//
//  Created by Nagata Asami on 27/1/26.
//

import SwiftUI
import NimbleViews
import IDeviceSwift
import OSLog

struct BulkInstallProgressView: View {
    var app: AppInfoPresentable
    @StateObject var viewModel = InstallerStatusViewModel()
    
    @AppStorage("Feather.installationMethod") private var _installationMethod: Int = 0
    @AppStorage("Feather.serverMethod") private var _serverMethod: Int = 0
    @StateObject var installer: ServerInstaller
    @State private var _isWebviewPresenting = false
    @State private var progressTask: Task<Void, Never>?

    // MARK: Stall watchdog
    // Some installs finish packaging but the iOS install prompt never
    // appears (or the transfer stalls), leaving the app spinning forever.
    // The watchdog notices when nothing has moved for a while and re-fires
    // the prompt — the automated version of closing and re-queueing it.
    @State private var _watchdogTask: Task<Void, Never>?
    @State private var _lastActivity = Date()
    @State private var _lastProgress: Double = 0
    @State private var _lastStatusRank: Int = -1
    @State private var _retryCount = 0

    private let _stallTimeout: TimeInterval = 25
    private let _maxRetries = 3
    
    init(app: AppInfoPresentable) {
        self.app = app
        let method = UserDefaults.standard.integer(forKey: "Feather.installationMethod")
        let viewModel = InstallerStatusViewModel(isIdevice: method == 1)
        self._viewModel = StateObject(wrappedValue: viewModel)
        self._installer = StateObject(wrappedValue: try! ServerInstaller(app: app, viewModel: viewModel))
    }
    
    var body: some View {
        VStack {
            InstallProgressView(app: app, viewModel: viewModel)
        }
        .sheet(isPresented: $_isWebviewPresenting) {
            SafariRepresentableView(url: installer.pageEndpoint).ignoresSafeArea()
        }
        .onReceive(viewModel.$status) { newStatus in
            if case .ready = newStatus {
                _triggerReadyAction()
            }
            
            if case .installing = newStatus {
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

            // A new phase means the install is making progress — reset the
            // stall timer so the watchdog doesn't interrupt healthy installs.
            _lastActivity = Date()

            switch newStatus {
            case .completed, .broken(_):
                progressTask?.cancel()
                progressTask = nil
                _watchdogTask?.cancel()
                _watchdogTask = nil
                BackgroundAudioManager.shared.stop()
            default:
                break
            }
        }
        .onAppear(perform: _install)
        .onAppear {
            BackgroundAudioManager.shared.start()
            _startStallWatchdog()
        }
        .onDisappear {
            progressTask?.cancel()
            progressTask = nil
            _watchdogTask?.cancel()
            _watchdogTask = nil
            BackgroundAudioManager.shared.stop()
        }
    }

    // Fires the actual install prompt for the current server method.
    // Extracted so both the initial `.ready` transition and the watchdog
    // retry can trigger it.
    private func _triggerReadyAction() {
        if _serverMethod == 0 {
            if let url = URL(string: installer.iTunesLink) {
                // Route through the coordinator instead of opening directly.
                // If many apps fire itms-services opens at the same instant
                // (e.g. a 19-app batch), iOS drops some and those apps never
                // get an install prompt. The coordinator spaces the opens out
                // so each one registers. Watchdog re-fires go through it too.
                InstallPromptCoordinator.shared.enqueue {
                    UIApplication.shared.open(url)
                }
            }
        } else if _serverMethod == 1 {
            _isWebviewPresenting = true
        }
    }
    
    private func _install() {
        Task.detached {
            do {
                let handler = await ArchiveHandler(app: app, viewModel: viewModel)
                try await handler.move()
                
                let packageUrl = try await handler.archive()
                
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
                } else if await _installationMethod == 1 {
                    let proxy = await InstallationProxy(viewModel: viewModel)
                    try await proxy.install(at: packageUrl, suspend: app.identifier == Bundle.main.bundleIdentifier!)
                }
                
            } catch {
                await MainActor.run {
                    HeartbeatManager.shared.start(true)
                }
            }
        }
    }
    
    // Watches for a stalled install: no phase change and no download
    // progress for `_stallTimeout` seconds while still in a non-terminal
    // state. When that happens it re-fires the install (up to `_maxRetries`
    // times), which is the automated equivalent of the manual
    // close-and-requeue workaround.
    private func _startStallWatchdog() {
        _watchdogTask?.cancel()
        _lastActivity = Date()
        _lastProgress = 0
        _lastStatusRank = -1
        _retryCount = 0

        _watchdogTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // check every 2s
                if Task.isCancelled { break }

                let status = viewModel.status
                let rank = _statusRank(status)
                let progress = viewModel.installProgress

                // Terminal — stop watching.
                if case .completed = status { break }
                if case .broken = status { break }

                // Forward movement (new phase or more download progress)
                // resets the stall timer.
                if rank != _lastStatusRank || progress > _lastProgress + 0.001 {
                    _lastStatusRank = rank
                    _lastProgress = progress
                    _lastActivity = Date()
                    continue
                }

                let stalledFor = Date().timeIntervalSince(_lastActivity)
                guard stalledFor >= _stallTimeout else { continue }

                // Only the server/prompt method can be revived by re-firing
                // the prompt; leave the idevice proxy method untouched.
                guard _installationMethod == 0 else { continue }

                if _retryCount < _maxRetries {
                    _retryCount += 1
                    _lastActivity = Date()
                    Logger.misc.info("Install for \(app.identifier ?? "?") stalled ~\(Int(stalledFor))s — requeueing (attempt \(_retryCount)/\(_maxRetries))")

                    // Drop any stale progress polling; the fresh prompt
                    // restarts the whole manifest → payload → install exchange.
                    progressTask?.cancel()
                    progressTask = nil
                    _triggerReadyAction()
                } else {
                    Logger.misc.info("Install for \(app.identifier ?? "?") stalled and exhausted retries")
                    break
                }
            }
        }
    }

    private func _statusRank(_ status: InstallerStatusViewModel.InstallerStatus) -> Int {
        switch status {
        case .none: return 0
        case .ready: return 1
        case .sendingManifest: return 2
        case .sendingPayload: return 3
        case .installing: return 4
        case .completed: return 5
        case .broken: return 6
        }
    }

    private func startInstallProgressPolling(
        bundleID: String,
        viewModel: InstallerStatusViewModel
    ) -> Task<Void, Never> {

        Task.detached(priority: .background) {
            var hasStarted = false

            while !Task.isCancelled {
                let rawProgress = await UIApplication.installProgress(for: bundleID) ?? 0.0

                if rawProgress > 0 {
                    hasStarted = true
                }

                let progress = await hasStarted
                    ? _normalizeInstallProgress(rawProgress)
                    : 0.0

                Logger.misc.info("Install progress for \(bundleID): \(progress) - \(rawProgress) - \(viewModel.installProgress)")

                await MainActor.run {
                    viewModel.installProgress = progress
                }

                if hasStarted && rawProgress == 0 {
                    await MainActor.run {
                        viewModel.installProgress = 1.0
                        viewModel.status = .completed(.success(()))
                        print(viewModel.installProgress)
                    }
                    break
                }

                try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
            }
        }
    }

    private func _normalizeInstallProgress(_ rawProgress: Double) -> Double {
        min(1.0, max(0.0, (rawProgress - 0.6) / 0.3))
    }
}

// Serializes install-prompt opens so they don't stampede iOS. Each app in a
// bulk install would otherwise call UIApplication.open(itms-services://…) at
// nearly the same time; iOS drops opens that arrive too close together, so a
// random app in a large batch never gets its prompt. This queues them and
// leaves a small gap between each so every one registers.
@MainActor
final class InstallPromptCoordinator {
    static let shared = InstallPromptCoordinator()

    // Minimum gap between consecutive opens. Raise it if a large batch still
    // occasionally drops one; lower it if prompting feels too slow.
    private let _spacing: TimeInterval = 0.6

    private var _queue: [() -> Void] = []
    private var _isDraining = false

    private init() {}

    func enqueue(_ action: @escaping () -> Void) {
        _queue.append(action)
        guard !_isDraining else { return }
        _isDraining = true
        _drain()
    }

    private func _drain() {
        guard !_queue.isEmpty else {
            _isDraining = false
            return
        }

        let next = _queue.removeFirst()
        next()

        DispatchQueue.main.asyncAfter(deadline: .now() + _spacing) { [weak self] in
            self?._drain()
        }
    }
}

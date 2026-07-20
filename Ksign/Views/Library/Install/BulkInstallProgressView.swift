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

    // MARK: Install queue
    // Tracks this install's slot in the shared concurrency-limited queue so
    // only a few installs run at once. Released exactly once (on finish, on
    // watchdog give-up, or on disappear).
    @State private var _hasSlot = false
    @State private var _slotReleased = false
    @State private var _installTask: Task<Void, Never>?
    
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
            
            // Only the server method needs this poller. The idevice path gets
            // real progress from installation_proxy's own callback, so running
            // both means two writers fighting over `installProgress` — and this
            // loop's completion guess could end the row early.
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
                // Free our slot so the next queued install can begin.
                _releaseSlotIfNeeded()
            default:
                break
            }
        }
        .onAppear {
            BackgroundAudioManager.shared.start()
            _beginQueuedInstall()
        }
        .onDisappear {
            _installTask?.cancel()
            _installTask = nil
            progressTask?.cancel()
            progressTask = nil
            _watchdogTask?.cancel()
            _watchdogTask = nil
            BackgroundAudioManager.shared.stop()
            // If the view goes away before finishing, don't hold the slot.
            _releaseSlotIfNeeded()
        }
    }

    // Waits for a free slot in the shared install queue, then starts. Only
    // `InstallQueueCoordinator`'s max run at once; the rest queue here. The
    // watchdog is started only once we actually begin, so its stall timer
    // doesn't run (and burn retries) while we're still waiting in line.
    private func _beginQueuedInstall() {
        _installTask = Task { @MainActor in
            // Waits for a slot. Returns false if cancelled while waiting
            // (e.g. the sheet was dismissed before our turn came up).
            let gotSlot = await InstallQueueCoordinator.shared.acquire()
            guard gotSlot, !Task.isCancelled else { return }
            _hasSlot = true
            _startStallWatchdog()
            _install()
        }
    }

    private func _releaseSlotIfNeeded() {
        guard _hasSlot, !_slotReleased else { return }
        _slotReleased = true
        InstallQueueCoordinator.shared.release()
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
                // Previously this silently restarted the heartbeat and left the
                // row spinning forever, so a failed install was indistinguishable
                // from one still in progress. Report it: setting `.broken` also
                // lets the status handler free this row's queue slot.
                Logger.misc.error("Install failed for \(app.identifier ?? "?"): \(error.localizedDescription)")
                await MainActor.run {
                    viewModel.status = .broken(error)
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
                    // Mark it failed so the terminal handler frees our queue
                    // slot — otherwise a permanently-stuck install would block
                    // everything still waiting in line behind it.
                    viewModel.status = .broken(InstallQueueError.stalled)
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

// Limits how many installs run at once. Each BulkInstallProgressView acquires
// a slot before starting and releases it when it finishes (or gives up), so a
// large batch installs a few at a time instead of all at once — the device
// can't actually install many simultaneously, and flooding it is what leaves
// apps permanently stuck. This is the same "queue it, don't stampede" fix used
// for signing and importing, applied to installs.
@MainActor
final class InstallQueueCoordinator {
    static let shared = InstallQueueCoordinator()

    // How many installs may be active at once. Tune to taste.
    private let _maxConcurrent = 3

    private var _activeCount = 0

    private init() {}

    // Waits until a slot is free, then claims it and returns true. Returns
    // false if the calling task is cancelled while waiting (e.g. the sheet was
    // dismissed) — in that case no slot is claimed, so nothing leaks. Because
    // this actor runs one task at a time, the check-and-claim is atomic and two
    // installs can never grab the same slot.
    func acquire() async -> Bool {
        while true {
            if Task.isCancelled { return false }
            if _activeCount < _maxConcurrent {
                _activeCount += 1
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        }
    }

    func release() {
        _activeCount = max(0, _activeCount - 1)
    }
}

enum InstallQueueError: LocalizedError {
    case stalled
    var errorDescription: String? {
        "The install stalled and couldn't be completed. You can try installing it again."
    }
}

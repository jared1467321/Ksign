//
//  InstallJob.swift
//  Ksign
//

import SwiftUI
import Combine
import IDeviceSwift
import OSLog
import Darwin

// Cheap, advisory headroom for this process. Apple documents
// `os_proc_available_memory()` as the current app memory limit minus this
// process's footprint; it can change at any time, so every log samples fresh.
private func _availableProcessMemoryMB() -> UInt64 {
	UInt64(os_proc_available_memory()) / 1_048_576
}

// A point-in-time view of the process's memory envelope. `availableBytes` is
// intentionally sampled fresh every time; Apple explicitly documents it as an
// advisory value that can change whenever the app does work. `phys_footprint`
// is paired with it only to estimate the *current* process budget, not to infer
// how much physical RAM the device has.
private struct _ProcessMemorySnapshot {
	let availableBytes: UInt64
	let footprintBytes: UInt64
	let budgetBytes: UInt64
}

private func _processPhysicalFootprintBytes() -> UInt64? {
	var info = task_vm_info_data_t()
	var count = mach_msg_type_number_t(
		MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
	)

	let result = withUnsafeMutablePointer(to: &info) { pointer in
		pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
			task_info(
				mach_task_self_,
				task_flavor_t(TASK_VM_INFO),
				rebound,
				&count
			)
		}
	}

	guard result == KERN_SUCCESS else { return nil }
	return UInt64(info.phys_footprint)
}

// A status may already be enqueued on MainActor when Retry/Cancel arrives.
// Capture its generation on the publisher's queue, before that delivery hop.
private final class InstallStatusEpoch: @unchecked Sendable {
	private let lock = NSLock()
	private var value: UUID? = UUID()
	var current: UUID? {
		lock.lock()
		defer { lock.unlock() }
		return value
	}
	func advance() {
		lock.lock()
		value = UUID()
		lock.unlock()
	}
	func cancel() {
		lock.lock()
		value = nil
		lock.unlock()
	}
	func matches(_ epoch: UUID?) -> Bool { epoch != nil && current == epoch }
}

// Server-method install progress is polled at 10 Hz so the Live Activity can
// stay responsive, but SwiftUI does not need ten ObservableObject publications
// per second per app. Retain only the newest numeric value, publish at most 5 Hz
// while active, and publish nothing while the app is inactive/locked. Status
// transitions are intentionally NOT routed through this bridge because they
// drive install control flow and must continue immediately in the background.
final class InstallProgressUIBridge {
	static let shared = InstallProgressUIBridge()

	private struct Pending {
		var latest: (() -> Void)?
		var deliveryQueued = false
	}

	private let _lock = NSLock()
	private var _isAppActive = false
	private var _pending: [ObjectIdentifier: Pending] = [:]
	private var _observers: [NSObjectProtocol] = []
	private let _presentationInterval: TimeInterval = 0.2

	private init() {
		let center = NotificationCenter.default

		_observers.append(center.addObserver(
			forName: UIApplication.willResignActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			self?._setAppActive(false)
		})

		_observers.append(center.addObserver(
			forName: UIApplication.didEnterBackgroundNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			self?._setAppActive(false)
		})

		_observers.append(center.addObserver(
			forName: UIApplication.didBecomeActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			self?._setAppActive(true)
		})

		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			self._setAppActive(UIApplication.shared.applicationState == .active)
		}
	}

	deinit {
		for observer in _observers {
			NotificationCenter.default.removeObserver(observer)
		}
	}

	func submit(_ value: Double, to viewModel: InstallerStatusViewModel) {
		let key = ObjectIdentifier(viewModel)
		var shouldQueueDelivery = false

		_lock.lock()
		var entry = _pending[key] ?? Pending()
		entry.latest = { [weak viewModel] in
			viewModel?.installProgress = value
		}

		if _isAppActive && !entry.deliveryQueued {
			entry.deliveryQueued = true
			shouldQueueDelivery = true
		}

		_pending[key] = entry
		_lock.unlock()

		if shouldQueueDelivery {
			_queueDelivery(for: key, after: _presentationInterval)
		}
	}

	private func _queueDelivery(for key: ObjectIdentifier, after delay: TimeInterval) {
		DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
			self?._deliverLatest(for: key)
		}
	}

	private func _deliverLatest(for key: ObjectIdentifier) {
		var update: (() -> Void)?

		_lock.lock()
		guard _isAppActive, var entry = _pending[key] else {
			if var entry = _pending[key] {
				entry.deliveryQueued = false
				_pending[key] = entry
			}
			_lock.unlock()
			return
		}

		update = entry.latest
		entry.latest = nil
		_pending[key] = entry
		_lock.unlock()

		update?()

		var shouldQueueAgain = false
		_lock.lock()
		if var entry = _pending[key] {
			if _isAppActive, entry.latest != nil {
				shouldQueueAgain = true
				_pending[key] = entry
			} else if entry.latest == nil {
				_pending.removeValue(forKey: key)
			} else {
				entry.deliveryQueued = false
				_pending[key] = entry
			}
		}
		_lock.unlock()

		if shouldQueueAgain {
			_queueDelivery(for: key, after: _presentationInterval)
		}
	}

	private func _setAppActive(_ active: Bool) {
		var keysToFlush: [ObjectIdentifier] = []

		_lock.lock()
		_isAppActive = active

		if active {
			for key in Array(_pending.keys) {
				guard var entry = _pending[key],
					entry.latest != nil,
					!entry.deliveryQueued
				else { continue }

				entry.deliveryQueued = true
				_pending[key] = entry
				keysToFlush.append(key)
			}
		}
		_lock.unlock()

		for key in keysToFlush {
			_queueDelivery(for: key, after: 0)
		}
	}
}

// One app's install.
//
// All of this used to live inside `BulkInstallProgressView` as `@State` and
// `@StateObject`, which meant the install died with the view: dismiss the
// sheet and the row's state was gone, so re-presenting it started everything
// over. Moving it into an object owned by `InstallSession` lets the install
// outlive whatever is (or isn't) on screen, which is what makes a collapsible
// drawer possible.
//
// The logic below is the same logic that was in the view — the server-method-
// only progress poller, the queue
// slot handling. Only where it *lives* changed.
@MainActor
final class InstallJob: ObservableObject, Identifiable {
	nonisolated let id = UUID()
	let app: AppInfoPresentable

	let viewModel: InstallerStatusViewModel
	// Created when the job actually takes a queue slot, not when it's made.
	// `ServerInstaller` starts a TLS server in its initialiser, and jobs are all
	// constructed up front — so picking twenty apps used to stand up twenty
	// servers at once when only three can ever install. Also skipped entirely
	// on the idevice path, which never touches the server.
	private(set) var installer: ServerInstaller?

	// Coarse, discrete state for anything watching a *batch* rather than a
	// single row. Deliberately not tied directly to `viewModel.installProgress`:
	// the session samples all jobs on its own 0.4-second cadence so one poller
	// cannot redraw the entire drawer on every sample.
	enum Phase: Equatable {
		case queued, running, completed, failed
	}

	@Published private(set) var phase: Phase = .queued

	// Batched-prompt role. The server + local method collapses several apps'
	// prompts into one: a group shares a single confirmation served by the
	// `host`, whose manifest lists every `member`. `pending` = batching but not
	// yet built; `awaiting` = built and waiting for the session to place it in a
	// group; `none` = not batching (idevice, external server, or a manual retry
	// that fell back to a solo prompt).
	enum BatchRole { case none, pending, awaiting, host, member }
	@Published private(set) var batchRole: BatchRole = .none

	// A member keeps a weak link to its host purely to tell whether the shared
	// prompt has been accepted yet (host has left `.ready`).
	private weak var _batchHost: InstallJob?

	// Fixed at construction from the same settings the session reads.
	private let _willBatch: Bool

	private let _installationMethod: Int
	private let _serverMethod: Int

	private var _cancellables = Set<AnyCancellable>()
	private var _installTask: Task<Void, Never>?
	private var _packagingTask: Task<Void, Never>?
	private var _packagingAttempt: PackagingAttempt?
	private var _retryAfterPackaging = false
	private let _statusEpoch = InstallStatusEpoch()

	// MARK: Install queue
	// One flag instead of the `_hasSlot`/`_slotReleased` pair. The coordinator
	// tracks holders by identity now, so releasing twice — or releasing
	// something that never held a slot — is harmless, and there's nothing left
	// for a second flag to guard against.
	private var _holdsSlot = false
	private var _started = false

	// Where `ArchiveHandler` built this job's .ipa, so it can be deleted once
	// the install is genuinely over. Kept as a URL rather than the handler
	// itself: the handler is built inside a detached task and isn't Sendable,
	// and a URL is all that's needed to clean up.
	private var _archiveWorkDir: URL?

	// Throws rather than `try!`-ing the way the view did: `ServerInstaller`
	// starts a Vapor server in its initialiser, and a port collision took the
	// whole app down. Now the session logs it and skips that one app.
	init(app: AppInfoPresentable) throws {
		self.app = app

		let method = UserDefaults.standard.integer(forKey: "Feather.installationMethod")
		self._installationMethod = method
		self._serverMethod = UserDefaults.standard.integer(forKey: "Feather.serverMethod")

		// Batching applies only to the local server method (method 0, server 0) —
		// the one where Ksign builds and serves the manifest itself. idevice has no
		// prompt to collapse; the external server builds its own plist elsewhere.
		self._willBatch = (method == 0 && self._serverMethod == 0)
		self.batchRole = self._willBatch ? .pending : .none

		let viewModel = InstallerStatusViewModel(isIdevice: method == 1)
		self.viewModel = viewModel
	}

	// Idempotent. Throws if the server can't be stood up, which the caller
	// turns into a normal `.broken` failure so the slot is freed properly.
	private func _ensureInstaller() throws {
		guard _installationMethod == 0, installer == nil else { return }
		// Local (server 0) installs are served by the group's host, not each app,
		// so build without a server — the host stands one up when it fires and
		// serves everyone. External (server 1) still serves its own payload for
		// palera.in to fetch, so it starts serving now.
		let serves = _serverMethod != 0
		let jobID = id
		let method = _installationMethod
		let bundleID = app.identifier
		let statusModel = viewModel

		installer = try ServerInstaller(
			app: app,
			viewModel: viewModel,
			startsServer: serves,
			statusReporter: { status in
				BulkInstallLiveActivityReporter.shared.updateStatus(jobID: jobID, status: status)

				// Start the server-method progress monitor from Vapor's worker
				// callback itself. Previously this waited for the @MainActor status
				// subscriber, which may not run until the app becomes active again.
				guard method == 0 else { return }

				switch status {
				case .installing:
					guard let bundleID else { return }
					ServerInstallProgressMonitor.shared.start(
						id: jobID,
						bundleID: bundleID,
						onProgress: { progress in
							BulkInstallLiveActivityReporter.shared.updateInstall(
								jobID: jobID,
								progress: progress
							)
							InstallProgressUIBridge.shared.submit(progress, to: statusModel)
						},
						onCompleted: {
							let completed = InstallerStatusViewModel.InstallerStatus.completed(.success(()))
							BulkInstallLiveActivityReporter.shared.updateStatus(
								jobID: jobID,
								status: completed
							)
							InstallProgressUIBridge.shared.submit(1, to: statusModel)
							DispatchQueue.main.async {
								statusModel.status = completed
							}
						}
					)

				case .completed, .broken:
					ServerInstallProgressMonitor.shared.stop(id: jobID)

				default:
					break
				}
			}
		)
	}

	// Replaces the view's `.onAppear`. Idempotent — a redraw can't restart it.
	func start() {
		guard !_started else { return }
		_started = true

		// Mirror primitive progress on the publisher's own delivery queue before
		// hopping to MainActor for the drawer. This subscription remains alive with
		// the job even when no install view is currently being rendered.
		let liveActivityJobID = id
		let statusEpoch = _statusEpoch
		viewModel.$status
			.sink { status in
				let epoch = statusEpoch.current
				BulkInstallLiveActivityReporter.shared.updateStatus(
					jobID: liveActivityJobID,
					status: status,
					isCurrent: { statusEpoch.matches(epoch) }
				)
			}
			.store(in: &_cancellables)

		// Packaging reports directly from its attempt. Echoing delayed UI progress
		// back into that reporter could replace a newer worker value with an old
		// one, and would lose the attempt's cancellation guard.

		viewModel.$installProgress
			.removeDuplicates()
			.sink { progress in
				BulkInstallLiveActivityReporter.shared.updateInstall(
					jobID: liveActivityJobID,
					progress: progress
				)
			}
			.store(in: &_cancellables)

		// UI state and queue coordination still belong on MainActor.
		viewModel.$status
			.map { (status: $0, epoch: statusEpoch.current) }
			.receive(on: DispatchQueue.main)
			.sink { [weak self] event in
				Task { @MainActor in
					guard statusEpoch.matches(event.epoch) else { return }
					self?._handleStatus(event.status)
				}
			}
			.store(in: &_cancellables)

		// `self.` throughout is not noise: this was a struct before, where
		// implicit capture is allowed. In a class an escaping closure requires
		// it, and a weak capture means a cancelled job waiting in the queue
		// isn't kept alive by its own pending task.
		// Captured up front: `id` is a property, and a class's escaping closure
		// can't reach one implicitly.
		let jobId = id

		_installTask = Task { @MainActor [weak self] in
			// Waits for a slot. Returns false if cancelled while waiting.
			let gotSlot = await InstallQueueCoordinator.shared.acquire(for: jobId)
			// `acquire` returns false only when it was cancelled *before*
			// claiming anything, so there's nothing to hand back here.
			guard gotSlot else { return }
			// Past this point a slot is genuinely held, so every exit has to
			// release it — including cancellation landing in the gap between
			// the claim and this check, or the job having failed while it sat
			// in the queue.
			guard !Task.isCancelled, let self, self.phase == .queued else {
				InstallQueueCoordinator.shared.release(jobId)
				return
			}
			self._holdsSlot = true
			self.phase = .running

			do {
				try self._ensureInstaller()
			} catch {
				self.viewModel.status = .broken(error)
				return
			}

			self._install()
		}
	}

	// Whether the archive has already been built and handed to the server.
	// `packageUrl` is set once, immediately before the install prompt fires,
	// and never cleared — so this is the dividing line between "the expensive
	// work is done and this job just needs poking" and "this never got off
	// the ground". It's what lets one Retry button do the right thing.
	var hasBuiltPackage: Bool { installer?.packageUrl != nil }

	// Whether `start()` has released this job to build yet. The session admits
	// batched jobs a group at a time rather than all at once, so an unstarted job
	// is one that's queued but hasn't been let go to build.
	var hasStarted: Bool { _started }

	// True while this job is sitting at the install prompt. A member reads this
	// on its host to tell whether the shared prompt has been accepted yet.
	var isAtReady: Bool {
		if case .ready = viewModel.status { return true }
		return false
	}


	// Called by the session when it forms a group. The host serves a manifest
	// listing itself plus every member; only the host opens the prompt.
	func becomeBatchHost(memberInstallers: [ServerInstaller]) {
		batchRole = .host
		installer?.setHosted(memberInstallers)
	}

	func becomeBatchMember(host: InstallJob) {
		batchRole = .member
		_batchHost = host
	}

	// Fires the host's shared prompt — same path as a normal `.ready`, but its
	// manifest now carries the whole group.
	func fireBatchedPrompt() {
		_triggerReadyAction()
	}

	// Manual retry, from the row's context menu.
	//
	// The common case is an install prompt that was dismissed by accident:
	// the package is built, the server is still serving it, and the job is
	// simply sitting idle at `.sendingManifest` waiting for a payload request
	// that will never come. Nothing is broken, so nothing needs rebuilding.
	func retry() {
		_statusEpoch.advance()
		// A manual retry always re-prompts this one app on its own — the shared
		// group prompt has already happened, so fold it back to a solo install.
		if batchRole == .host { installer?.setHosted([]) }
		batchRole = .none
		_batchHost = nil

		// Clear anything left over from the previous attempt.
		ServerInstallProgressMonitor.shared.stop(id: id)
		_installTask?.cancel()
		_installTask = nil
		_packagingAttempt?.cancel()
		if _packagingTask != nil {
			_retryAfterPackaging = true
			_packagingTask?.cancel()
			return
		}

		// Slot handling follows what the job is *currently holding*, not which
		// path it's about to take — those are separate questions. A job stuck
		// mid-flight never reached a terminal state, so it still holds its
		// slot and must keep it. A job showing "Failed" already handed its
		// slot back and has to queue up again like anyone else.
		//
		// Getting this backwards doesn't throw: it either leaks a slot (the
		// queue quietly shrinks until nothing starts) or runs more installs at
		// once than the limit allows. Both only surface much later.
		if _holdsSlot {
			phase = .running
			_resume()
		} else {
			_reacquireAndResume()
		}
	}

	// Re-queues for a build slot, then rebuilds (or re-fires) once it lands.
	// Shared by a plain retry and by a batched app rejoining the pool.
	private func _reacquireAndResume() {
		_holdsSlot = false
		phase = .queued

		let jobId = id

		_installTask = Task { @MainActor [weak self] in
			let gotSlot = await InstallQueueCoordinator.shared.acquire(for: jobId)
			guard gotSlot else { return }
			guard !Task.isCancelled, let self, self.phase == .queued else {
				InstallQueueCoordinator.shared.release(jobId)
				return
			}
			self._holdsSlot = true
			self.phase = .running

			do {
				try self._ensureInstaller()
			} catch {
				self.viewModel.status = .broken(error)
				return
			}

			self._resume()
		}
	}

	// Still sitting at a shared prompt that hasn't been accepted — dismissed, or
	// the group fired and iOS never pulled this item. Retry reclaims these, since
	// they genuinely still need installing.
	var isStuckAtPrompt: Bool {
		(batchRole == .host || batchRole == .member) && isAtReady
	}

	// Folded into a prompt (host or member) and not finished — whether stuck at
	// the prompt or stuck partway through installing (installed on device but
	// never reported back). The paused "clear stuck installs" action reclaims
	// all of these; there's no watchdog to clear a stalled one automatically.
	var isInFlightGroupMember: Bool {
		(batchRole == .host || batchRole == .member)
			&& phase != .completed && phase != .failed
	}

	// Drops a batched app back into the ready pool so the session can fold it
	// into a fresh manifest with whatever else is waiting or still building.
	func rejoinPool() {
		_statusEpoch.advance()
		// Shed any role from the manifest it was just in. A demoted host also
		// stops serving — a fresh host will serve the regrouped manifest.
		if batchRole == .host {
			installer?.setHosted([])
			installer?.shutDown()
		}
		_batchHost = nil
		ServerInstallProgressMonitor.shared.stop(id: id)

		if hasBuiltPackage {
			// Server and package are still alive — no rebuild, no slot needed. Park
			// straight back into the pool, show it waiting again rather than
			// mid-install, and let the session regroup it.
			batchRole = .awaiting
			phase = .running
			viewModel.status = .ready
			InstallSession.shared.jobBecameReadyForBatch(self)
		} else {
			// Failed before a package existed — rebuild from the queue; it parks
			// back into the pool on its own once it's ready.
			batchRole = .pending
			if _holdsSlot {
				phase = .running
				_resume()
			} else {
				_reacquireAndResume()
			}
		}
	}

	private func _resume() {
		if hasBuiltPackage {
			// Re-fire the prompt against the package that's already built: set
			// status back to `.ready` and the status handler opens it again.
			// No re-archiving, near-instant.
			viewModel.status = .ready
		} else {
			// Never got as far as a package, so there's nothing to re-prompt
			// with. Start over from the top — the ordinary first-run path.
			_install()
		}
	}

	// Replaces the view's `.onDisappear`. Only called when the session is
	// actually tearing the job down — *not* when the drawer collapses.
	func cancel() {
		_statusEpoch.cancel()
		_retryAfterPackaging = false
		_packagingAttempt?.cancel()
		_packagingTask?.cancel()
		_installTask?.cancel()
		_installTask = nil
		ServerInstallProgressMonitor.shared.stop(id: id)
		_releaseSlotIfNeeded()
		// Covers the case `.completed` doesn't: a failed job the user dismisses
		// by hand, or the whole drawer being cleared mid-batch.
		_cleanupArchive()
	}

	// Clearing `packageUrl` matters as much as deleting the directory. It's
	// what `hasBuiltPackage` reads, and a retry that believes a package still
	// exists would re-prompt against a file that's gone and serve a 404
	// instead of rebuilding.
	private func _cleanupArchive() {
		guard let dir = _archiveWorkDir else { return }
		_archiveWorkDir = nil
		installer?.packageUrl = nil
		ArchiveHandler.cleanup(workDir: dir)
	}

	private func _handleStatus(_ newStatus: InstallerStatusViewModel.InstallerStatus) {
		// Per-job ActivityKit *state* does not live here. Jobs forward primitive
		// progress/status callbacks into one batch reporter, which derives a single
		// aggregate snapshot; the controller then serializes/coalesces that snapshot.
		// The drawer still reads each job directly.

		if case .ready = newStatus {
			switch batchRole {
			case .none:
				// Not batching, or forced solo by a manual retry: prompt now.
				_triggerReadyAction()
			case .pending:
				// Built and ready. Park instead of prompting and let the session
				// fold this into a group; it picks host vs. member and fires the
				// one shared prompt. Hand the build slot back now — the server and
				// package stay alive, but a parked app mustn't tie up a slot, or the
				// pool couldn't grow past the build limit. Building is what's
				// rationed, not waiting to be prompted.
				batchRole = .awaiting
				_releaseSlotIfNeeded()
				InstallSession.shared.jobBecameReadyForBatch(self)
			case .host:
				// Re-entering `.ready` (a manual retry of the host) re-fires the shared
				// prompt, whose manifest still lists every member.
				_triggerReadyAction()
			case .awaiting, .member:
				// The host owns the prompt for these; stay quiet.
				break
			}
		}

		if case .sendingPayload = newStatus, _serverMethod == 1 {
			InstallSession.shared.dismissWebview(for: self)
		}

		switch newStatus {
		case .completed, .broken:
			if case .broken = newStatus, _packagingTask != nil {
				// An external installer failure may arrive before packaging ends.
				// Its worker must not subsequently resurrect the job as .ready.
				_packagingAttempt?.cancel()
				_packagingTask?.cancel()
			}
			ServerInstallProgressMonitor.shared.stop(id: id)
			// This one was missed before. A job that failed while still queued
			// left its task sitting in `acquire()`, which would later claim a
			// slot for an already-dead job and quietly hold it.
			_installTask?.cancel()
			_installTask = nil
			// Free our slot so the next queued install can begin.
			_releaseSlotIfNeeded()

			if case .completed = newStatus {
				phase = .completed
				// The payload has been transferred and installed, so the
				// staged .ipa is dead weight. Failures deliberately keep
				// theirs: `retry()` re-fires the prompt against the existing
				// package instead of rebuilding it, which is the whole reason
				// retrying a dismissed prompt is instant.
				_cleanupArchive()
			} else {
				phase = .failed
			}

			InstallSession.shared.jobDidFinish(self)
		default:
			break
		}
	}

	private func _releaseSlotIfNeeded() {
		guard _holdsSlot else { return }
		_holdsSlot = false
		InstallQueueCoordinator.shared.release(id)
	}

	// Fires the actual install prompt for the current server method. Both the
	// initial `.ready` transition and a manual retry come through here.
	private func _triggerReadyAction() {
		if _serverMethod == 0 {
			// This app (the host, or a solo retry) serves the prompt, so its
			// server has to be up before the link opens. Members never reach here.
			do {
				try installer?.startServing()
			} catch {
				viewModel.status = .broken(error)
				return
			}
			if let link = installer?.iTunesLink, let url = URL(string: link) {
				// Route through the coordinator instead of opening directly.
				// If many apps fire itms-services opens at the same instant
				// iOS drops some, and those apps never get an install prompt.
				InstallPromptCoordinator.shared.enqueue {
					UIApplication.shared.open(url)
				}
			}
		} else if _serverMethod == 1 {
			// Presented by the drawer, not by the row: a row can be scrolled
			// out of sight or collapsed behind the lip, and a sheet presented
			// from a view that isn't visible never appears.
			InstallSession.shared.presentWebview(for: self)
		}
	}

	private func _install() {
		// Rejoin/retry can arrive while a synchronous native writer is alive.
		// Invalidate it now, but restart only after its worker has cleaned up.
		if _packagingTask != nil {
			_retryAfterPackaging = true
			_packagingAttempt?.cancel()
			_packagingTask?.cancel()
			return
		}
		let app = self.app
		let viewModel = self.viewModel
		let method = _installationMethod
		let installer = self.installer
		let jobID = self.id
		_statusEpoch.advance()
		_packagingAttempt?.cancel()
		let attempt = PackagingAttempt()
		_packagingAttempt = attempt

		_packagingTask = Task.detached { [weak self] in
			let handler = ArchiveHandler(
				app: app,
				viewModel: viewModel,
				progressReporter: { progress in
					BulkInstallLiveActivityReporter.shared.updatePackage(
						jobID: jobID, progress: progress, isCurrent: { attempt.isCurrent }
					)
				},
				attempt: attempt,
				jobID: jobID
			)
			var handedOff = false
			var failure: Error?
			do {
				try await handler.move()
				try Task.checkCancellation()
				let packageURL = try await handler.archive()
				try Task.checkCancellation()
				guard attempt.isCurrent else { throw CancellationError() }

				if method == 0 {
					BulkInstallLiveActivityReporter.shared.updateStatus(
						jobID: jobID, status: .ready, isCurrent: { attempt.isCurrent }
					)
					let workDir = handler.workDir
					handedOff = await MainActor.run { [weak self] in
						guard let self, self._packagingAttempt?.id == attempt.id,
						      attempt.isCurrent else { return false }
						// Ownership transfers atomically with .ready. Until this point
						// only the worker may delete its work directory.
						self._archiveWorkDir = workDir
						installer?.packageUrl = packageURL
						viewModel.packageProgress = 1
						viewModel.status = .ready
						return true
					}
				} else if method == 1 {
					let proxy = await InstallationProxy(viewModel: viewModel)
					try Task.checkCancellation()
					try await proxy.install(at: packageURL, suspend: app.identifier == Bundle.main.bundleIdentifier!)
					// Keep worker ownership until idevice finishes consuming the IPA.
				}
			} catch let error as CancellationError {
				// Cancellation is not an install failure, including a queued lease.
				// An unrelated dependency cancellation still needs a terminal state.
				if !Task.isCancelled && attempt.isCurrent { failure = error }
			} catch {
				failure = error
			}
			if !handedOff { handler.cleanup() }
			let packagingError = failure
			if let packagingError {
				BulkInstallLiveActivityReporter.shared.updateStatus(
					jobID: jobID, status: .broken(packagingError), isCurrent: { attempt.isCurrent }
				)
			}
			await MainActor.run { [weak self] in
				self?._packagingFinished(attempt, error: packagingError)
			}
		}
	}

	private func _packagingFinished(_ attempt: PackagingAttempt, error: Error?) {
		guard _packagingAttempt?.id == attempt.id else { return }
		_packagingTask = nil
		// Retain the last token until replacement/cancellation, so pending UI
		// deliveries from a finished attempt can also be invalidated on retry.
		if _retryAfterPackaging {
			_retryAfterPackaging = false
			if _holdsSlot {
				phase = .running
				_resume()
			} else {
				_reacquireAndResume()
			}
		} else if attempt.isCurrent, let error {
			Logger.misc.error("Install failed for \(self.app.identifier ?? "?"): \(error.localizedDescription)")
			viewModel.status = .broken(error)
			HeartbeatManager.shared.start(true)
		}
	}

}

// Polls LSApplicationWorkspace from a detached worker for server-method installs.
// Starting this monitor is driven directly by ServerInstaller's Vapor callback,
// not by SwiftUI or an @MainActor status observer.
final class ServerInstallProgressMonitor {
	static let shared = ServerInstallProgressMonitor()

	private let _queue = DispatchQueue(
		label: "nya.asami.ksign.server-install-progress",
		qos: .userInitiated
	)
	private struct _Entry {
		let generation: UUID
		let task: Task<Void, Never>
	}
	private var _tasks: [UUID: _Entry] = [:]

	private init() { }

	func start(
		id: UUID,
		bundleID: String,
		onProgress: @escaping (Double) -> Void,
		onCompleted: @escaping () -> Void
	) {
		_queue.async {
			guard self._tasks[id] == nil else { return }

			let generation = UUID()
			let task = Task.detached(priority: .userInitiated) { [weak self] in
				var hasStarted = false
				let startedAt = Date()
				let wasInstalledAtStart = UIApplication.isAppInstalled(bundleID)

				while !Task.isCancelled {
					let rawProgress = UIApplication.installProgress(for: bundleID)

					if let rawProgress, rawProgress > 0 {
						hasStarted = true
					}

					let progress = hasStarted
						? Self._normalize(rawProgress ?? 0)
						: 0
					onProgress(progress)

					let finishedByEdge = hasStarted && rawProgress == nil
					let finishedByPresence = !wasInstalledAtStart
						&& !hasStarted
						&& rawProgress == nil
						&& Date().timeIntervalSince(startedAt) > 8
						&& UIApplication.isAppInstalled(bundleID)

					if finishedByEdge || finishedByPresence {
						onProgress(1)
						onCompleted()
						self?._remove(id: id, generation: generation)
						return
					}

					try? await Task.sleep(nanoseconds: 100_000_000)
				}

				self?._remove(id: id, generation: generation)
			}

			self._tasks[id] = _Entry(generation: generation, task: task)
		}
	}

	func stop(id: UUID) {
		_queue.async {
			self._tasks.removeValue(forKey: id)?.task.cancel()
		}
	}

	private func _remove(id: UUID, generation: UUID) {
		_queue.async {
			guard self._tasks[id]?.generation == generation else { return }
			self._tasks.removeValue(forKey: id)
		}
	}

	private static func _normalize(_ rawProgress: Double) -> Double {
		min(1, max(0, (rawProgress - 0.6) / 0.3))
	}
}

// Serializes install-prompt opens so they don't stampede iOS. Each app in a
// bulk install would otherwise call UIApplication.open(itms-services://…) at
// nearly the same time; iOS drops opens that arrive too close together, so a
// random app in a large batch never gets its prompt.
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

// Limits how many installs run at once. Each job acquires a slot before
// starting and releases it when it finishes (or gives up), so a large batch
// installs a few at a time instead of all at once.
//
// For high-concurrency batch building, the configured limit is a ceiling, not
// a command to immediately launch that many jobs. Admissions ramp one at a time
// while the coordinator watches the process's real memory envelope. It learns
// how much headroom each newly admitted build actually consumes and stops
// admitting more while memory is still falling or there isn't room for another
// observed build plus a reserve. No device-RAM-sized constants are used.
@MainActor
final class InstallQueueCoordinator {
	static let shared = InstallQueueCoordinator()

	private struct _AdmissionObservation {
		let id: UUID
		let startedAt: TimeInterval
		let startAvailableBytes: UInt64
		let startFootprintBytes: UInt64
		var minimumAvailableBytes: UInt64
		var maximumFootprintBytes: UInt64
		var lastMeaningfulLowAt: TimeInterval
		var lastMeaningfulLowBytes: UInt64
	}

	private struct _HeadroomSample {
		let time: TimeInterval
		let availableBytes: UInt64
	}

	// The session's requested concurrency. For batching this remains 5; adaptive
	// memory control only decides how quickly/how far toward that ceiling it is
	// safe to ramp at this moment.
	private var _configuredMaxConcurrent = 3

	// Kernel pressure is the emergency brake. It never rewrites the configured
	// ceiling. Warning/critical both block *new* admissions; existing holders are
	// allowed to finish naturally. Once the kernel reports normal again, a short
	// cooldown ends and the adaptive controller takes over the ramp from there.
	private var _memoryPressureLimit: Int?
	private var _memoryRecoveryTask: Task<Void, Never>?

	private let _memoryPressureQueue = DispatchQueue(
		label: "nya.asami.ksign.install-memory-pressure",
		qos: .userInitiated
	)
	private var _memoryPressureSource: DispatchSourceMemoryPressure?

	// Adaptive admission state. The timing values merely control observation
	// cadence; unlike the old MB buckets, none encode an assumed device size.
	private let _admissionObservationWindow: TimeInterval = 0.8
	private let _headroomSettleWindow: TimeInterval = 0.35
	private let _recentTrendWindow: TimeInterval = 1.2
	private let _sampleInterval: TimeInterval = 0.10
	private let _footprintSampleInterval: TimeInterval = 0.50

	private var _admissionObservation: _AdmissionObservation?
	private var _learnedBuildCostBytes: Double?
	private var _recentHeadroom: [_HeadroomSample] = []
	private var _lastHeadroomSampleAt: TimeInterval = 0
	private var _cachedFootprintBytes: UInt64?
	private var _cachedBudgetBytes: UInt64?
	private var _cachedFootprintAt: TimeInterval = 0
	private var _lastAdaptiveState: String?
	private var _didLogSnapshotFailure = false

	// Who holds a slot, rather than how many are held.
	//
	// A bare counter trusts every caller to increment and decrement exactly
	// once. Tracking identity makes release/claim idempotent and also gives the
	// adaptive learner an exact count of expensive build jobs currently alive.
	private var _holders: Set<UUID> = []
	private var _isPaused = false

	private init() {
		_startMemoryPressureMonitoring()
	}

	var activeCount: Int { _holders.count }

	private var _usesAdaptiveMemoryAdmission: Bool {
		// The ordinary install path is intentionally capped at 3 already. The
		// adaptive ramp exists for the higher-concurrency batch builder, where 5
		// remains the desired ceiling when memory permits it.
		_configuredMaxConcurrent > 3
	}

	private var _effectiveMaxConcurrent: Int {
		guard let pressureLimit = _memoryPressureLimit else {
			return _configuredMaxConcurrent
		}
		return min(_configuredMaxConcurrent, pressureLimit)
	}

	func setMaxConcurrent(_ n: Int) {
		let newValue = max(1, n)
		guard newValue != _configuredMaxConcurrent else { return }

		_configuredMaxConcurrent = newValue
		_resetAdaptiveLearning()
	}

	// Pausing works by simply declining to hand out slots. Jobs already holding
	// one never consult this again, so anything mid-build/install runs to
	// completion untouched.
	func setPaused(_ paused: Bool) {
		_isPaused = paused
	}

	// Waits until a slot is free, then claims it for `id` and returns true.
	// Returns false if the calling task is cancelled while waiting. Because this
	// runs on MainActor, check + admission + claim are atomic: waiting jobs cannot
	// all sample the same headroom and stampede through together.
	func acquire(for id: UUID) async -> Bool {
		while true {
			if Task.isCancelled { return false }

			_reclaimOrphans()

			let effectiveMax = _effectiveMaxConcurrent
			if !_isPaused, effectiveMax > 0, _holders.count < effectiveMax {
				if !_usesAdaptiveMemoryAdmission || _adaptiveAdmissionIsSafe(for: id) {
					_holders.insert(id)
					ArchiveMemoryCoordinator.shared.setBuildCount(_holders.count)
					if _usesAdaptiveMemoryAdmission {
						_beginAdmissionObservation(for: id)
					}
					return true
				}
			}

			// A paused/pressure-blocked queue can sleep longer. During adaptive
			// throttling we intentionally wake at the sampling cadence so the next
			// slot can be admitted as soon as headroom stabilizes or recovers.
			let fullyStopped = _isPaused || effectiveMax == 0
			try? await Task.sleep(
				nanoseconds: fullyStopped
					? 500_000_000
					: UInt64(_sampleInterval * 1_000_000_000)
			)
		}
	}

	func release(_ id: UUID) {
		guard _holders.remove(id) != nil else { return }
		ArchiveMemoryCoordinator.shared.setBuildCount(_holders.count)

		// Capture one last sample while the just-finished job's footprint is still
		// representative. If this was the newest admission, its observation can
		// now contribute to the learned cost even if no waiter happened to sample
		// after the observation window elapsed.
		if _usesAdaptiveMemoryAdmission {
			let now = ProcessInfo.processInfo.systemUptime
			if let snapshot = _adaptiveMemorySnapshot(at: now, forceFootprint: true) {
				_recordHeadroomSample(snapshot.availableBytes, at: now)
				_updateAdmissionObservation(with: snapshot, at: now)
			}
			if _admissionObservation?.id == id {
				_finalizeAdmissionObservation(now: now, force: true)
			}
		}
	}

	// MARK: - Adaptive memory admission

	private func _adaptiveAdmissionIsSafe(for id: UUID) -> Bool {
		let now = ProcessInfo.processInfo.systemUptime
		guard let snapshot = _adaptiveMemorySnapshot(at: now), snapshot.budgetBytes > 0 else {
			if !_didLogSnapshotFailure {
				_didLogSnapshotFailure = true
				Logger.misc.warning(
					"Adaptive archive admission couldn't read TASK_VM_INFO; falling back to configured limit plus kernel pressure events"
				)
			}
			return true
		}

		_didLogSnapshotFailure = false
		_recordHeadroomSample(snapshot.availableBytes, at: now)
		_updateAdmissionObservation(with: snapshot, at: now)

		// Never admit the next job immediately behind the previous one. The newest
		// job gets a short observation window in which its real footprint/headroom
		// effect becomes visible. This closes the old race where five waiters all
		// saw essentially the same pre-allocation memory state.
		if let observation = _admissionObservation {
			let age = now - observation.startedAt
			if age < _admissionObservationWindow {
				_logAdaptiveHold(
					"observing newest build",
					snapshot: snapshot,
					estimatedCostBytes: _estimatedNextBuildCost(snapshot: snapshot)
				)
				return false
			}

			let sinceLow = now - observation.lastMeaningfulLowAt
			if sinceLow < _headroomSettleWindow {
				_logAdaptiveHold(
					"headroom still settling",
					snapshot: snapshot,
					estimatedCostBytes: _estimatedNextBuildCost(snapshot: snapshot)
				)
				return false
			}

			_finalizeAdmissionObservation(now: now, force: false)
		}

		let estimatedCost = _estimatedNextBuildCost(snapshot: snapshot)
		let reserve = _dynamicReserveBytes(snapshot: snapshot, estimatedCostBytes: estimatedCost)
		let required = estimatedCost + reserve

		guard Double(snapshot.availableBytes) > required else {
			_logAdaptiveHold(
				"insufficient learned headroom",
				snapshot: snapshot,
				estimatedCostBytes: estimatedCost,
				reserveBytes: reserve
			)
			return false
		}

		// Even with adequate absolute headroom, don't add another build while the
		// latest samples show it is still materially falling. The threshold is
		// expressed as a fraction of one learned/provisional build cost, not MB.
		if _recentHeadroomIsFalling(estimatedCostBytes: estimatedCost, now: now) {
			_logAdaptiveHold(
				"headroom is still falling",
				snapshot: snapshot,
				estimatedCostBytes: estimatedCost,
				reserveBytes: reserve
			)
			return false
		}

		let activeAfter = _holders.count + 1
		let availableMB = _bytesToMB(snapshot.availableBytes)
		let footprintMB = _bytesToMB(snapshot.footprintBytes)
		let budgetMB = _bytesToMB(snapshot.budgetBytes)
		let learnedMB = _bytesToMB(estimatedCost)
		let reserveMB = _bytesToMB(reserve)
		let state = "admit-\(activeAfter)"
		if _lastAdaptiveState != state {
			_lastAdaptiveState = state
			Logger.misc.info(
				"Adaptive archive admission -> \(activeAfter)/\(self._configuredMaxConcurrent); available=\(availableMB) MB, footprint=\(footprintMB) MB, budget=\(budgetMB) MB, estimatedNext=\(learnedMB) MB, reserve=\(reserveMB) MB"
			)
		}
		return true
	}

	private func _beginAdmissionObservation(for id: UUID) {
		let now = ProcessInfo.processInfo.systemUptime
		guard let snapshot = _adaptiveMemorySnapshot(at: now) else {
			_admissionObservation = nil
			return
		}

		_recordHeadroomSample(snapshot.availableBytes, at: now)
		_admissionObservation = _AdmissionObservation(
			id: id,
			startedAt: now,
			startAvailableBytes: snapshot.availableBytes,
			startFootprintBytes: snapshot.footprintBytes,
			minimumAvailableBytes: snapshot.availableBytes,
			maximumFootprintBytes: snapshot.footprintBytes,
			lastMeaningfulLowAt: now,
			lastMeaningfulLowBytes: snapshot.availableBytes
		)
	}

	// `os_proc_available_memory()` is cheap enough to sample at the admission
	// cadence; `task_info` is not. Keep available memory fresh on every decision
	// while sampling physical footprint only twice per second (or explicitly at
	// release). That preserves the useful budget estimate without turning a large
	// waiter pool into a storm of expensive Mach calls.
	private func _adaptiveMemorySnapshot(
		at now: TimeInterval,
		forceFootprint: Bool = false
	) -> _ProcessMemorySnapshot? {
		let available = UInt64(os_proc_available_memory())
		let footprint: UInt64
		let budget: UInt64

		if !forceFootprint,
		   let cachedFootprint = _cachedFootprintBytes,
		   let cachedBudget = _cachedBudgetBytes,
		   now - _cachedFootprintAt < _footprintSampleInterval {
			footprint = cachedFootprint
			budget = cachedBudget
		} else {
			guard let sampled = _processPhysicalFootprintBytes() else { return nil }
			let sampledBudget = available &+ sampled
			_cachedFootprintBytes = sampled
			_cachedBudgetBytes = sampledBudget
			_cachedFootprintAt = now
			footprint = sampled
			budget = sampledBudget
		}

		return _ProcessMemorySnapshot(
			availableBytes: available,
			footprintBytes: footprint,
			budgetBytes: budget
		)
	}

	private func _updateAdmissionObservation(
		with snapshot: _ProcessMemorySnapshot,
		at now: TimeInterval
	) {
		guard var observation = _admissionObservation else { return }

		observation.minimumAvailableBytes = min(
			observation.minimumAvailableBytes,
			snapshot.availableBytes
		)
		observation.maximumFootprintBytes = max(
			observation.maximumFootprintBytes,
			snapshot.footprintBytes
		)

		// Ignore tiny scheduler/cache wiggles when deciding whether the newest job
		// is still driving headroom lower. "Meaningful" scales with the currently
		// estimated cost of one build, so it adapts with both device and workload.
		let estimatedCost = _estimatedNextBuildCost(snapshot: snapshot)
		let meaningfulDrop = max(1.0, estimatedCost * 0.03)
		if observation.lastMeaningfulLowBytes > snapshot.availableBytes {
			let drop = Double(observation.lastMeaningfulLowBytes - snapshot.availableBytes)
			if drop >= meaningfulDrop {
				observation.lastMeaningfulLowBytes = snapshot.availableBytes
				observation.lastMeaningfulLowAt = now
			}
		}

		_admissionObservation = observation
	}

	private func _finalizeAdmissionObservation(now: TimeInterval, force: Bool) {
		guard let observation = _admissionObservation else { return }
		if !force {
			guard now - observation.startedAt >= _admissionObservationWindow else { return }
			guard now - observation.lastMeaningfulLowAt >= _headroomSettleWindow else { return }
		}

		let availableDrop = observation.startAvailableBytes > observation.minimumAvailableBytes
			? observation.startAvailableBytes - observation.minimumAvailableBytes
			: 0
		let footprintRise = observation.maximumFootprintBytes > observation.startFootprintBytes
			? observation.maximumFootprintBytes - observation.startFootprintBytes
			: 0
		let observedCost = Double(max(availableDrop, footprintRise))

		if observedCost > 0 {
			if let learned = _learnedBuildCostBytes {
				// React quickly when a build is more expensive than expected, but let
				// the estimate decay slowly when later builds are cheaper. That bias is
				// deliberate: underestimating the next admission is the dangerous side.
				if observedCost > learned {
					_learnedBuildCostBytes = learned * 0.35 + observedCost * 0.65
				} else {
					_learnedBuildCostBytes = learned * 0.90 + observedCost * 0.10
				}
			} else {
				_learnedBuildCostBytes = observedCost
			}

			if let learnedNow = _learnedBuildCostBytes {
				Logger.misc.info(
					"Adaptive archive learner observed \(self._bytesToMB(observedCost)) MB; learned build cost=\(self._bytesToMB(learnedNow)) MB"
				)
			}
		}

		_admissionObservation = nil
	}

	private func _estimatedNextBuildCost(snapshot: _ProcessMemorySnapshot) -> Double {
		if let learned = _learnedBuildCostBytes, learned > 0 {
			return learned
		}

		// Bootstrap without assuming device RAM: before the first build teaches us
		// its cost, divide the process's *measured current budget* into the desired
		// concurrency plus one reserve share. The estimate disappears as soon as
		// real observations are available.
		return Double(snapshot.budgetBytes) / Double(_configuredMaxConcurrent + 1)
	}

	private func _dynamicReserveBytes(
		snapshot: _ProcessMemorySnapshot,
		estimatedCostBytes: Double
	) -> Double {
		// Always retain at least one equal-share slice of the current process
		// budget. After learning begins, also reserve one whole observed next-build
		// cost. Recent headroom volatility can enlarge the reserve further.
		let budgetShare = Double(snapshot.budgetBytes) / Double(_configuredMaxConcurrent + 1)
		let volatility = _recentHeadroomVolatilityBytes()
		return max(budgetShare, estimatedCostBytes, volatility)
	}

	private func _recordHeadroomSample(_ availableBytes: UInt64, at now: TimeInterval) {
		guard now - _lastHeadroomSampleAt >= _sampleInterval * 0.75 else { return }
		_lastHeadroomSampleAt = now
		_recentHeadroom.append(_HeadroomSample(time: now, availableBytes: availableBytes))

		let cutoff = now - _recentTrendWindow
		_recentHeadroom.removeAll { $0.time < cutoff }
	}

	private func _recentHeadroomVolatilityBytes() -> Double {
		guard let first = _recentHeadroom.first else { return 0 }
		var low = first.availableBytes
		var high = first.availableBytes
		for sample in _recentHeadroom.dropFirst() {
			low = min(low, sample.availableBytes)
			high = max(high, sample.availableBytes)
		}
		return Double(high - low)
	}

	private func _recentHeadroomIsFalling(
		estimatedCostBytes: Double,
		now: TimeInterval
	) -> Bool {
		let cutoff = now - _admissionObservationWindow
		guard let first = _recentHeadroom.first(where: { $0.time >= cutoff }),
			  let last = _recentHeadroom.last,
			  last.time > first.time,
			  first.availableBytes > last.availableBytes else {
			return false
		}

		let drop = Double(first.availableBytes - last.availableBytes)
		return drop >= max(1.0, estimatedCostBytes * 0.25)
	}

	private func _logAdaptiveHold(
		_ reason: String,
		snapshot: _ProcessMemorySnapshot,
		estimatedCostBytes: Double,
		reserveBytes: Double? = nil
	) {
		let state = "hold:\(reason):\(_holders.count)"
		guard state != _lastAdaptiveState else { return }
		_lastAdaptiveState = state

		let availableMB = _bytesToMB(snapshot.availableBytes)
		let footprintMB = _bytesToMB(snapshot.footprintBytes)
		let estimatedMB = _bytesToMB(estimatedCostBytes)
		if let reserveBytes {
			Logger.misc.notice(
				"Adaptive archive hold at \(self._holders.count)/\(self._configuredMaxConcurrent): \(reason, privacy: .public); available=\(availableMB) MB, footprint=\(footprintMB) MB, estimatedNext=\(estimatedMB) MB, reserve=\(self._bytesToMB(reserveBytes)) MB"
			)
		} else {
			Logger.misc.notice(
				"Adaptive archive hold at \(self._holders.count)/\(self._configuredMaxConcurrent): \(reason, privacy: .public); available=\(availableMB) MB, footprint=\(footprintMB) MB, estimatedNext=\(estimatedMB) MB"
			)
		}
	}

	private func _bytesToMB(_ bytes: UInt64) -> Int {
		Int(bytes / 1_048_576)
	}

	private func _bytesToMB(_ bytes: Double) -> Int {
		Int(max(0, bytes) / 1_048_576)
	}

	private func _resetAdaptiveLearning() {
		_admissionObservation = nil
		_learnedBuildCostBytes = nil
		_recentHeadroom.removeAll(keepingCapacity: true)
		_lastHeadroomSampleAt = 0
		_cachedFootprintBytes = nil
		_cachedBudgetBytes = nil
		_cachedFootprintAt = 0
		_lastAdaptiveState = nil
		_didLogSnapshotFailure = false
	}

	// MARK: - Memory pressure

	private func _startMemoryPressureMonitoring() {
		let source = DispatchSource.makeMemoryPressureSource(
			eventMask: .all,
			queue: _memoryPressureQueue
		)

		source.setEventHandler { [weak self] in
			let event = source.data
			let availableMB = _availableProcessMemoryMB()

			Task { @MainActor [weak self] in
				self?._handleMemoryPressure(event, availableMB: availableMB)
			}
		}

		_memoryPressureSource = source
		source.activate()
	}

	private func _handleMemoryPressure(
		_ event: DispatchSource.MemoryPressureEvent,
		availableMB: UInt64
	) {
		// Pressure notifications are deliberately only the emergency brake. The
		// proactive adaptive gate above should normally have throttled first.
		if event.contains(.critical) {
			_memoryRecoveryTask?.cancel()
			_memoryRecoveryTask = nil
			_memoryPressureLimit = 0
			Logger.misc.critical(
				"Memory pressure CRITICAL; blocking new archive admissions. active=\(self._holders.count), available=\(availableMB) MB"
			)
			return
		}

		if event.contains(.warning) {
			_memoryRecoveryTask?.cancel()
			_memoryRecoveryTask = nil
			_memoryPressureLimit = 0
			Logger.misc.warning(
				"Memory pressure WARNING; blocking new archive admissions. active=\(self._holders.count), available=\(availableMB) MB"
			)
			return
		}

		guard event.contains(.normal), _memoryPressureLimit != nil else { return }
		_beginMemoryRecovery(availableMB: availableMB)
	}

	private func _beginMemoryRecovery(availableMB: UInt64) {
		_memoryRecoveryTask?.cancel()
		Logger.misc.notice(
			"Memory pressure returned to NORMAL; holding admissions briefly before adaptive recovery. active=\(self._holders.count), available=\(availableMB) MB"
		)

		_memoryRecoveryTask = Task { @MainActor [weak self] in
			do {
				try await Task.sleep(nanoseconds: 2_000_000_000)
				guard let self, !Task.isCancelled else { return }
				self._memoryPressureLimit = nil
				self._memoryRecoveryTask = nil
				// Do not force 1 -> 2 -> 5 here. Clearing the emergency brake merely
				// hands control back to the measured adaptive admission logic.
				Logger.misc.notice(
					"Memory-pressure cooldown complete; adaptive archive admission resumed. active=\(self._holders.count), available=\(_availableProcessMemoryMB()) MB"
				)
			} catch {
				// A fresh warning/critical event superseded this recovery.
			}
		}
	}

	// The safety net. Any slot held by a job the session no longer knows about
	// can't ever be released by its owner, because its owner is gone — reclaim it
	// on the next acquisition attempt instead of wedging the queue indefinitely.
	private func _reclaimOrphans() {
		let live = Set(InstallSession.shared.jobs.map { $0.id })
		let orphaned = _holders.subtracting(live)
		guard !orphaned.isEmpty else { return }

		_holders.subtract(orphaned)
		ArchiveMemoryCoordinator.shared.setBuildCount(_holders.count)
		Logger.misc.info("Install queue reclaimed \(orphaned.count) orphaned slot(s)")
	}
}

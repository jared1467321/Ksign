//
//  InstallJob.swift
//  Ksign
//

import SwiftUI
import Combine
import IDeviceSwift
import OSLog

// One app's install.
//
// All of this used to live inside `BulkInstallProgressView` as `@State` and
// `@StateObject`, which meant the install died with the view: dismiss the
// sheet and the row's state was gone, so re-presenting it started everything
// over. Moving it into an object owned by `InstallSession` lets the install
// outlive whatever is (or isn't) on screen, which is what makes a collapsible
// drawer possible.
//
// The logic below is the same logic that was in the view — the stall watchdog,
// the `.ready`-only refire, the server-method-only progress poller, the queue
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
	// single row. Deliberately not tied to `viewModel.installProgress`: that
	// updates on a 1ms poll, and republishing it up to the session would
	// redraw the whole drawer a thousand times a second.
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
	private var _progressTask: Task<Void, Never>?
	private var _watchdogTask: Task<Void, Never>?
	private var _installTask: Task<Void, Never>?

	// MARK: Stall watchdog
	private var _lastActivity = Date()
	private var _lastProgress: Double = 0
	private var _lastStatusRank: Int = -1
	private var _retryCount = 0

	private let _stallTimeout: TimeInterval = 45
	private let _maxRetries = 3

	// How long a batched member waits after the shared prompt is accepted (or
	// abandoned) before deciding iOS skipped it and firing its own prompt.
	private let _batchMemberFallback: TimeInterval = 12

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

	// Set by a manual retry so a doomed attempt gives its slot back in seconds
	// rather than sitting through the full stall window. Cleared the moment
	// real progress appears.
	private var _fastFailWindow = false

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
		installer = try ServerInstaller(app: app, viewModel: viewModel)
	}

	// Replaces the view's `.onAppear`. Idempotent — a redraw can't restart it.
	func start() {
		guard !_started else { return }
		_started = true

		// Replaces `.onReceive(viewModel.$status)`. Weak self so a finished
		// job isn't kept alive by its own subscription.
		viewModel.$status
			.receive(on: DispatchQueue.main)
			.sink { [weak self] status in
				Task { @MainActor in self?._handleStatus(status) }
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

			self._startStallWatchdog()
			self._install()
		}
	}

	// Whether the archive has already been built and handed to the server.
	// `packageUrl` is set once, immediately before the install prompt fires,
	// and never cleared — so this is the dividing line between "the expensive
	// work is done and this job just needs poking" and "this never got off
	// the ground". It's what lets one Retry button do the right thing.
	var hasBuiltPackage: Bool { installer?.packageUrl != nil }

	// True while this job is sitting at the install prompt. A member reads this
	// on its host to tell whether the shared prompt has been accepted yet.
	var isAtReady: Bool {
		if case .ready = viewModel.status { return true }
		return false
	}

	// This job's own app as a manifest item, for a host to collect its members'.
	var ownManifestItem: [String: Any]? { installer?.ownManifestItem }

	// Called by the session when it forms a group. The host serves a manifest
	// listing itself plus every member; only the host opens the prompt.
	func becomeBatchHost(memberItems: [[String: Any]]) {
		batchRole = .host
		installer?.extraManifestItems = memberItems
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
		// A manual retry always re-prompts this one app on its own — the shared
		// group prompt has already happened, so fold it back to a solo install.
		if batchRole == .host { installer?.extraManifestItems = [] }
		batchRole = .none
		_batchHost = nil

		// Clear anything left over from the previous attempt.
		_progressTask?.cancel()
		_progressTask = nil
		_watchdogTask?.cancel()
		_watchdogTask = nil
		_installTask?.cancel()
		_installTask = nil

		_retryCount = 0
		_fastFailWindow = true
		_lastActivity = Date()
		_lastProgress = 0
		_lastStatusRank = -1

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
			_startStallWatchdog()
			_resume()
		} else {
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

				self._startStallWatchdog()
				self._resume()
			}
		}
	}

	private func _resume() {
		if hasBuiltPackage {
			// Re-entering `.ready` runs the same path the watchdog's automatic
			// retries already use: the status handler picks it up and re-fires
			// the prompt. No new code, no re-archiving, near-instant.
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
		_installTask?.cancel()
		_installTask = nil
		_progressTask?.cancel()
		_progressTask = nil
		_watchdogTask?.cancel()
		_watchdogTask = nil
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
		if case .ready = newStatus {
			switch batchRole {
			case .none:
				// Not batching, or forced solo by a manual retry: prompt now.
				_triggerReadyAction()
			case .pending:
				// Built and ready. Park instead of prompting and let the session
				// fold this into a group; it picks host vs. member and fires the
				// one shared prompt.
				batchRole = .awaiting
				InstallSession.shared.jobBecameReadyForBatch(self)
			case .host:
				// Re-entering `.ready` (resume/auto-retry) re-fires the shared
				// prompt, whose manifest still lists every member.
				_triggerReadyAction()
			case .awaiting, .member:
				// The host owns the prompt for these; stay quiet.
				break
			}
		}

		// Server method only. The idevice path already gets real progress from
		// installation_proxy's callback, so running this too means two writers
		// fighting over `installProgress` — and this loop's own completion
		// guess can end the row early.
		if case .installing = newStatus, _installationMethod == 0, _progressTask == nil {
			_progressTask = _startInstallProgressPolling()
		}

		if case .sendingPayload = newStatus, _serverMethod == 1 {
			InstallSession.shared.dismissWebview(for: self)
		}

		// A new phase means the install is making progress — reset the stall
		// timer so the watchdog doesn't interrupt healthy installs.
		_lastActivity = Date()

		switch newStatus {
		case .completed, .broken:
			_progressTask?.cancel()
			_progressTask = nil
			_watchdogTask?.cancel()
			_watchdogTask = nil
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
	// initial `.ready` transition and the watchdog retry come through here.
	private func _triggerReadyAction() {
		if _serverMethod == 0 {
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
		let app = self.app
		let viewModel = self.viewModel
		let method = _installationMethod
		let installer = self.installer

		Task.detached {
			do {
				let handler = await ArchiveHandler(app: app, viewModel: viewModel)
				try await handler.move()

				let workDir = await handler.workDir
				let packageUrl = try await handler.archive()

				await MainActor.run { [weak self] in
					self?._archiveWorkDir = workDir
				}

				if method == 0 {
					await MainActor.run {
						installer?.packageUrl = packageUrl
						viewModel.status = .ready
					}
				} else if method == 1 {
					let proxy = await InstallationProxy(viewModel: viewModel)
					try await proxy.install(
						at: packageUrl,
						suspend: app.identifier == Bundle.main.bundleIdentifier!
					)
				}
			} catch {
				// A failed install used to be indistinguishable from one still
				// running. `.broken` also lets the status handler free the slot.
				Logger.misc.error("Install failed for \(app.identifier ?? "?"): \(error.localizedDescription)")
				await MainActor.run {
					viewModel.status = .broken(error)
					HeartbeatManager.shared.start(true)
				}
			}
		}
	}

	// Watches for a stalled install: no phase change and no download progress
	// for `_stallTimeout` seconds while still in a non-terminal state.
	private func _startStallWatchdog() {
		_watchdogTask?.cancel()
		_lastActivity = Date()
		_lastProgress = 0
		_lastStatusRank = -1
		_retryCount = 0

		_watchdogTask = Task { @MainActor [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: 2_000_000_000) // check every 2s
				if Task.isCancelled { break }
				guard let self else { break }

				let status = self.viewModel.status
				let rank = self._statusRank(status)
				// Covers both paths: idevice reports AFC upload via
				// `uploadProgress`, the server path via `installProgress`.
				let progress = max(self.viewModel.installProgress, self.viewModel.uploadProgress)

				// Terminal — stop watching.
				if case .completed = status { break }
				if case .broken = status { break }

				// Forward movement resets the stall timer.
				if rank != self._lastStatusRank || progress > self._lastProgress + 0.001 {
					self._lastStatusRank = rank
					self._lastProgress = progress
					self._lastActivity = Date()
					// Real movement — this attempt isn't doomed, so give it the
					// normal stall window from here on.
					self._fastFailWindow = false
					continue
				}

				// Batched jobs waiting on a shared prompt run on their own clock.
				switch self.batchRole {
				case .awaiting:
					// The session groups ready jobs within a tick or two — never a
					// stall, so keep resetting and let it be placed.
					self._lastActivity = Date()
					continue
				case .member:
					// While the host still sits at `.ready` the prompt just hasn't
					// been tapped yet — don't race the user with a second one. Once
					// the host advances (accepted) or dies (gave up), a member still
					// stuck at `.ready` was skipped by iOS, so give it its own prompt.
					let hostPending = self._batchHost.map { $0.isAtReady } ?? false
					if hostPending {
						self._lastActivity = Date()
						continue
					}
					if Date().timeIntervalSince(self._lastActivity) >= self._batchMemberFallback {
						Logger.misc.info("Batched app \(self.app.identifier ?? "?") wasn't picked up by the shared prompt — firing its own")
						self.batchRole = .none
						self._triggerReadyAction()
						self._lastActivity = Date()
					}
					continue
				case .none, .pending, .host:
					break
				}

				let stalledFor = Date().timeIntervalSince(self._lastActivity)
				// A manual retry gets a much shorter leash. Retrying something
				// that's simply broken shouldn't tie up a slot for the full
				// three-minute cycle before anyone finds out.
				let timeout = self._fastFailWindow ? 15.0 : self._stallTimeout
				guard stalledFor >= timeout else { continue }

				if self._installationMethod == 1 {
					// idevice: the AFC upload loop runs synchronous C calls and
					// can't be interrupted safely — firing a second upload while
					// the first still holds a file handle is worse than failing.
					Logger.misc.info("idevice install for \(self.app.identifier ?? "?") stalled ~\(Int(stalledFor))s — reporting")
					self.viewModel.status = .broken(InstallQueueError.stalled)
					break
				}

				// Server method: only re-fire when the prompt itself never
				// landed. Re-firing mid-transfer is what produced duplicate
				// prompts on apps that were working fine.
				guard case .ready = status else {
					self._lastActivity = Date()
					continue
				}

				if self._retryCount < self._maxRetries {
					self._retryCount += 1
					self._lastActivity = Date()
					Logger.misc.info("Install for \(self.app.identifier ?? "?") prompt never landed after ~\(Int(stalledFor))s — refiring (attempt \(self._retryCount)/\(self._maxRetries))")

					self._progressTask?.cancel()
					self._progressTask = nil
					self._triggerReadyAction()
				} else {
					Logger.misc.info("Install for \(self.app.identifier ?? "?") stalled and exhausted retries")
					// Mark it failed so the terminal handler frees the queue
					// slot — otherwise a stuck install blocks everything behind it.
					self.viewModel.status = .broken(InstallQueueError.stalled)
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

	private func _startInstallProgressPolling() -> Task<Void, Never>? {
		guard let bundleID = app.identifier else { return nil }
		let viewModel = self.viewModel

		return Task.detached(priority: .background) {
			var hasStarted = false

			while !Task.isCancelled {
				let rawProgress = await UIApplication.installProgress(for: bundleID) ?? 0.0

				if rawProgress > 0 {
					hasStarted = true
				}

				let progress = hasStarted
					? Self._normalizeInstallProgress(rawProgress)
					: 0.0

				await MainActor.run {
					viewModel.installProgress = progress
				}

				if hasStarted && rawProgress == 0 {
					await MainActor.run {
						viewModel.installProgress = 1.0
						viewModel.status = .completed(.success(()))
					}
					break
				}

				// Was 1ms. That's a private-API call plus a main-actor hop a
				// thousand times a second, per installing app, to drive a bar
				// that can't redraw faster than the display. 100ms is still
				// far smoother than anyone can perceive.
				try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
			}
		}
	}

	// `nonisolated` because the class is @MainActor, which this static would
	// otherwise inherit — and it's called from the detached polling task.
	// It's pure arithmetic on a Double, so there's nothing to isolate.
	nonisolated private static func _normalizeInstallProgress(_ rawProgress: Double) -> Double {
		min(1.0, max(0.0, (rawProgress - 0.6) / 0.3))
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
// installs a few at a time instead of all at once — the device can't actually
// install many simultaneously, and flooding it is what leaves apps stuck.
@MainActor
final class InstallQueueCoordinator {
	static let shared = InstallQueueCoordinator()

	// How many installs may be active at once. Raised to the batch group size
	// while batching server installs so a whole group can reach `.ready`
	// together, and set back down otherwise. Driven by `InstallSession`.
	private var _maxConcurrent = 3

	func setMaxConcurrent(_ n: Int) {
		_maxConcurrent = max(1, n)
	}

	// Who holds a slot, rather than how many are held.
	//
	// A bare counter trusts every caller to increment and decrement exactly
	// once, and three separate bugs have now come from that trust being
	// misplaced — a double release, a task that claimed a slot and returned
	// without giving it back, a dead job whose queued task claimed one later.
	// Tracking identity makes the operations idempotent: releasing twice does
	// nothing, releasing something that never held a slot does nothing, and
	// claiming twice can't double-count because it's a set.
	private var _holders: Set<UUID> = []
	private var _isPaused = false

	private init() {}

	var activeCount: Int { _holders.count }

	// Pausing works by simply declining to hand out slots. Jobs already
	// holding one never consult this again, so anything mid-install runs to
	// completion untouched — exactly the "let what's running finish" behaviour.
	func setPaused(_ paused: Bool) {
		_isPaused = paused
	}

	// Waits until a slot is free, then claims it for `id` and returns true.
	// Returns false if the calling task is cancelled while waiting — in that
	// case nothing is claimed. Because this runs on the main actor the
	// check-and-claim is atomic and two installs can't grab the same slot.
	func acquire(for id: UUID) async -> Bool {
		while true {
			if Task.isCancelled { return false }

			_reclaimOrphans()

			if !_isPaused, _holders.count < _maxConcurrent {
				_holders.insert(id)
				return true
			}
			// Back off while paused. A pause can last minutes, and a big batch
			// means one waiting task per queued app — no reason to have twenty
			// of them waking ten times a second to learn nothing has changed.
			try? await Task.sleep(nanoseconds: _isPaused ? 500_000_000 : 100_000_000)
		}
	}

	func release(_ id: UUID) {
		_holders.remove(id)
	}

	// The safety net. Any slot held by a job the session no longer knows about
	// can't ever be released by its owner, because its owner is gone — so the
	// queue reclaims it. This is why there's no "reset the queue" button: a
	// leak repairs itself on the next attempt to acquire, rather than needing
	// someone to notice the queue is wedged and press something.
	private func _reclaimOrphans() {
		let live = Set(InstallSession.shared.jobs.map { $0.id })
		let orphaned = _holders.subtracting(live)
		guard !orphaned.isEmpty else { return }

		_holders.subtract(orphaned)
		Logger.misc.info("Install queue reclaimed \(orphaned.count) orphaned slot(s)")
	}
}

enum InstallQueueError: LocalizedError {
	case stalled
	var errorDescription: String? {
		"The install stalled and couldn't be completed. You can try installing it again."
	}
}

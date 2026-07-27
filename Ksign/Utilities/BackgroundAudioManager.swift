//
//  BackgroundAudioManager.swift
//  Ksign
//
//  Created by Nagata Asami on 10/10/25.
//

import AVFoundation
import OSLog

// Keeps a silent audio graph running so iOS doesn't suspend the app while
// installs or downloads are still in flight.
//
// The keep-alive used to be claimed once and then trusted forever. It isn't
// trustworthy: `AVAudioEngine` stops on an audio session interruption (a call,
// an alarm, another app taking the session) and does not come back by itself,
// and `setActive(true)` can simply fail. Either way the old code logged once
// and the rest of the batch ran with no keep-alive at all — invisible until
// you locked the phone and installs quietly stopped.
//
// So this is a health check rather than a one-shot claim:
//
// 1. Callers register *identity*, not a count. `claim(.downloads)` twice is one
//    claim, and `release(.singleInstall)` twice is one release. The old integer
//    count leaked — `DownloadManager` called `start()` on every download list
//    change and `stop()` once, so the count never got back to zero and the
//    engine ran forever. Identity makes that impossible to get wrong.
//
// 2. Whenever anything is claimed, a watchdog re-checks that the engine really
//    is running and restarts it if not. Failures back off (1s, 2s, 4s … 30s)
//    so a genuinely broken engine can't turn into a hot loop hammering the
//    audio session from a timer.
//
// 3. The `backgroundAudio` option still gates everything. It gates the *engine*
//    rather than the claim, so the invariant is exact: option off, nothing
//    runs — including mid-batch, where turning it off now stops the engine on
//    the next check instead of at the end of the batch.
//
// 4. Every transition is reported to `BackgroundAudioStatus`, which is what the
//    speaker badge at the top of the screen reads. Reporting is transitions
//    only — `ensureRunning()` gets called every 0.4s during an install and the
//    watchdog every 2s, so anything that logged per check would drown the log
//    in noise. Nothing here reports while the engine is merely still healthy.
final class BackgroundAudioManager {
	static let shared = BackgroundAudioManager()

	// Who wants the app kept alive. Add a case rather than reusing one — two
	// features sharing a case would release each other's claim.
	enum Owner: String {
		case bulkInstalls
		case singleInstall
		case downloads
		case bulkExport

		// What the log and the badge call it. The raw value is an identity key,
		// not something to show a person.
		var displayName: String {
			switch self {
			case .bulkInstalls:		return "Bulk installs"
			case .singleInstall:	return "Install"
			case .downloads:		return "Downloads"
			case .bulkExport:		return "Bulk export"
			}
		}
	}

	// Reached from the main actor (installs) and from URLSession delegate
	// queues (downloads), so state is lock-guarded rather than isolated.
	private let _lock = NSLock()

	private let _engine = AVAudioEngine()
	private var _silence: AVAudioSourceNode?

	private var _owners: Set<Owner> = []

	// Only deactivate a session we actually activated.
	private var _sessionActive = false

	// Set when something external tells us the graph is no longer sound —
	// an interruption or a configuration change — so we restart even if
	// `isRunning` still says true.
	private var _needsRestart = false

	private var _failureStreak = 0
	private var _nextAttempt = Date.distantPast
	private var _watchdog: Task<Void, Never>?

	// True between a successful start and a deliberate stop. It's what separates
	// "started" from "restarted" in the log: if the engine is being started
	// while this is already true, it died on us rather than being asked to run.
	private var _running = false

	private init() {
		let center = NotificationCenter.default

		// Block-based rather than selector-based: this isn't an `NSObject`
		// subclass, so it can't vend `@objc` selectors.
		center.addObserver(
			forName: AVAudioSession.interruptionNotification,
			object: nil,
			queue: nil
		) { [weak self] notification in
			self?._handleInterruption(notification)
		}

		center.addObserver(
			forName: .AVAudioEngineConfigurationChange,
			object: _engine,
			queue: nil
		) { [weak self] _ in
			self?._handleConfigurationChange()
		}
	}

	var isRunning: Bool {
		_lock.lock()
		defer { _lock.unlock() }
		return _engine.isRunning
	}

	// MARK: - Claims

	// Idempotent. Call it as often as you like; the matching `release` is what
	// gives it up.
	func claim(_ owner: Owner) {
		_lock.lock()
		let inserted = _owners.insert(owner).inserted
		_lock.unlock()

		// Only the transition is worth a log line — callers claim repeatedly by
		// design, that's the whole point of identity claims.
		if inserted {
			_status.record(.claimed, owner.displayName)
		}

		// A fresh claim always gets an immediate attempt, even if an earlier
		// owner is sitting in a backoff window.
		_evaluate(force: inserted)
	}

	// Idempotent, so a caller that releases twice — or on a path it isn't sure
	// ran — can't pull the keep-alive out from under anyone else.
	func release(_ owner: Owner) {
		_lock.lock()
		let removed = _owners.remove(owner) != nil
		_lock.unlock()

		if removed {
			_status.record(.released, owner.displayName)
		}

		_evaluate(force: false)
	}

	// Cheap and safe to call on a timer. `InstallSession` already ticks every
	// 0.4s for aggregate progress and calls this from there, which is the
	// tightest check during the case that matters most; the watchdog below
	// covers everything else.
	func ensureRunning() {
		_evaluate(force: false)
	}

	// MARK: - The health check

	private func _evaluate(force: Bool) {
		_lock.lock()
		// Defers run last-in-first-out, so this publishes while the lock is
		// still held — which is fine, because publishing is an async hop to
		// main and never reaches back in here.
		defer { _lock.unlock() }
		defer { _publishLocked() }

		let optionEnabled = OptionsManager.shared.options.backgroundAudio
		let wanted = optionEnabled && !_owners.isEmpty

		guard wanted else {
			if _sessionActive || _engine.isRunning {
				_stopEngineLocked()

				_status.record(.stopped, optionEnabled
					? "nothing left to keep alive"
					: "background audio turned off in settings")
			}
			_stopWatchdogLocked()
			_failureStreak = 0
			_needsRestart = false
			_nextAttempt = .distantPast
			return
		}

		_startWatchdogLocked()

		if force {
			_failureStreak = 0
			_nextAttempt = .distantPast
		}

		guard _needsRestart || !_engine.isRunning else { return }
		guard Date() >= _nextAttempt else { return }

		_startEngineLocked()
	}

	private func _startEngineLocked() {
		do {
			let session = AVAudioSession.sharedInstance()

			try session.setCategory(.playback, options: [.mixWithOthers])
			try session.setActive(true)
			_sessionActive = true

			// Built once and kept. Attaching a new node per start leaked one
			// every time and left the graph in a state that wouldn't restart.
			if _silence == nil {
				let node = AVAudioSourceNode { _, _, _, audioBufferList -> OSStatus in
					let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
					for buffer in buffers {
						memset(buffer.mData, 0, Int(buffer.mDataByteSize))
					}
					return noErr
				}

				_engine.attach(node)
				_engine.connect(node, to: _engine.mainMixerNode, format: nil)
				_silence = node
			}

			if !_engine.isRunning {
				_engine.prepare()
				try _engine.start()
			}

			if _failureStreak > 0 {
				Logger.misc.info("Background audio recovered after \(self._failureStreak) failed attempt(s).")
			}

			if _running {
				// We thought it was running and here we are starting it again,
				// so something knocked it over: an interruption, a route
				// change, or a failed attempt we're now recovering from.
				_status.record(.restarted, _failureStreak > 0
					? "recovered after \(_failureStreak) failed attempt(s)"
					: "engine had stopped on its own")
			} else {
				let holders = _owners.map(\.displayName).sorted().joined(separator: ", ")

				_status.record(.started, holders.isEmpty
					? ""
					: "keeping the app awake for \(holders)")
			}

			_running = true
			_failureStreak = 0
			_needsRestart = false
			_nextAttempt = .distantPast
		} catch {
			// Note what is *not* here: the old version cleared the holder count
			// on failure, which threw away other features' claims and left the
			// keep-alive permanently unrecoverable. The claim survives; only
			// the attempt failed, and we'll try again.
			_failureStreak += 1
			_needsRestart = true

			let delay = min(30.0, pow(2.0, Double(min(_failureStreak - 1, 5))))
			_nextAttempt = Date().addingTimeInterval(delay)

			// Once per streak. A phone call lasting ten minutes shouldn't
			// write a log line every two seconds.
			if _failureStreak == 1 {
				Logger.misc.error("Background audio failed to start: \(error.localizedDescription). Will keep retrying while installs are active.")
			}

			// Unlike the os_log line above, every attempt is recorded — the
			// backoff caps at 30s, so the worst case is one line per half
			// minute, and seeing the retries is the point of the log.
			_status.record(.failed, "\(error.localizedDescription) — retrying in \(Int(delay))s (attempt \(_failureStreak))")
		}
	}

	private func _stopEngineLocked() {
		// `pause` rather than `stop`: it leaves the graph intact, so the next
		// start is a restart rather than a rebuild.
		_engine.pause()

		if _sessionActive {
			try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
			_sessionActive = false
		}

		// Deliberate, so the next start is a start rather than a restart.
		_running = false
	}

	// MARK: - Watchdog

	// Runs only while something is claimed. Slower than the install tick
	// because it exists to cover the callers that have no tick of their own,
	// notably downloads.
	private func _startWatchdogLocked() {
		guard _watchdog == nil else { return }

		_watchdog = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: 2_000_000_000)
				guard let self, !Task.isCancelled else { break }
				self._evaluate(force: false)
			}
		}
	}

	private func _stopWatchdogLocked() {
		_watchdog?.cancel()
		_watchdog = nil
	}

	// MARK: - System events

	private func _handleInterruption(_ notification: Notification) {
		guard
			let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
			let type = AVAudioSession.InterruptionType(rawValue: raw)
		else {
			return
		}

		_lock.lock()
		_needsRestart = true

		// Interruptions fire whether or not we care. Only worth a log line if
		// we were actually keeping something alive at the time.
		let relevant = !_owners.isEmpty

		switch type {
		case .began:
			// iOS has taken the session away; ours is no longer active and
			// there's nothing to deactivate later.
			_sessionActive = false
		default:
			// Interruption over — this is the moment restarting is most likely
			// to work, so clear any backoff we accumulated during it.
			_failureStreak = 0
			_nextAttempt = .distantPast
		}
		_lock.unlock()

		if relevant {
			switch type {
			case .began:
				_status.record(.interrupted, "a call or another app took the audio session")
			default:
				_status.record(.resumed, "session handed back, restarting")
			}
		}

		_evaluate(force: false)
	}

	// Route changes and hardware reconfiguration stop the engine without
	// telling anyone. `isRunning` catches most of it; this catches it sooner.
	private func _handleConfigurationChange() {
		_lock.lock()
		_needsRestart = true
		let relevant = !_owners.isEmpty
		_lock.unlock()

		if relevant {
			_status.record(.reconfigured, "hardware or route changed, rechecking the engine")
		}

		_evaluate(force: false)
	}

	// MARK: - Reporting

	// Everything the UI knows comes through here. Both calls hop to main
	// asynchronously, so they're safe to make with `_lock` held.
	private var _status: BackgroundAudioStatus { .shared }

	private func _publishLocked() {
		_status.update(
			isRunning: _engine.isRunning,
			owners: _owners.map(\.displayName).sorted()
		)
	}
}

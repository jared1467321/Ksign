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
// Two problems fixed here, both of which made keep-alive fail silently:
//
// 1. It now counts holders. Bulk installs, single installs and downloads all
//    share this one object, and a bare `stop()` from any of them silenced the
//    others — a finished download could suspend a running install batch.
//
// 2. It now survives a stop/start cycle. The previous version attached a fresh
//    source node on every `start()` and never detached the old one, while
//    `stop()` tore the engine down and deactivated the shared audio session.
//    That combination doesn't reliably come back, and the only error handling
//    was a `print` — so the second batch in an app session would run with no
//    keep-alive at all and give no indication of it.
final class BackgroundAudioManager {
	static let shared = BackgroundAudioManager()

	private let _engine = AVAudioEngine()
	private var _silence: AVAudioSourceNode?
	private var _holders = 0

	private init() {}

	var isRunning: Bool { _engine.isRunning }

	// Claim the keep-alive. Every `start()` must be balanced by exactly one
	// `stop()`, and only the last one out actually stops the engine.
	func start() {
		guard OptionsManager.shared.options.backgroundAudio else { return }

		_holders += 1
		guard _holders == 1 else { return }

		_startEngine()
	}

	func stop() {
		guard _holders > 0 else { return }

		_holders -= 1
		guard _holders == 0 else { return }

		_stopEngine()
	}

	private func _startEngine() {
		do {
			let session = AVAudioSession.sharedInstance()

			try session.setCategory(.playback, options: [.mixWithOthers])
			try session.setActive(true)

			// Built once and kept. Attaching a new node per `start()` leaked
			// one every time and left the graph in a state that wouldn't
			// restart cleanly.
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
		} catch {
			// This was a bare `print`, which is exactly why the failure looked
			// like nothing at all — just apps that stop installing once the
			// app is backgrounded.
			Logger.misc.error("Background audio failed to start: \(error.localizedDescription)")
			_holders = 0
		}
	}

	private func _stopEngine() {
		// `pause` rather than `stop`: it leaves the graph intact, so the next
		// start is a restart rather than a rebuild.
		_engine.pause()
		try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
	}
}

//
//  BackgroundAudioStatus.swift
//  Ksign
//

import Foundation
import SwiftUI

// One thing that happened to the silent-audio keep-alive.
//
// `BackgroundAudioManager` is deliberately not an `ObservableObject`: it is
// touched from the main actor, from URLSession delegate queues and from its own
// watchdog task, and making it observable would mean either isolating it (which
// the download path can't do) or publishing from arbitrary threads (which
// SwiftUI won't tolerate). So the manager stays a plain lock-guarded class and
// reports into this, which is the only thing the UI ever looks at.
struct BackgroundAudioEvent: Identifiable, Equatable {
	enum Kind {
		case claimed
		case released
		case started
		case restarted
		case stopped
		case failed
		case interrupted
		case resumed
		case reconfigured
		// Anything to do with the Dynamic Island pill: whether it was asked
		// for, whether the system actually started it, and how it ended. The
		// pill only exists while the app is backgrounded, so without a trace
		// here there is no way to tell "never submitted" from "submitted and
		// silently reclaimed".
		case island
	}

	let id = UUID()
	let date: Date
	let kind: Kind
	let detail: String

	var title: String {
		switch kind {
		case .claimed:		return "Claimed"
		case .released:		return "Released"
		case .started:		return "Started"
		case .restarted:	return "Restarted"
		case .stopped:		return "Stopped"
		case .failed:		return "Failed to start"
		case .interrupted:	return "Interrupted"
		case .resumed:		return "Interruption ended"
		case .reconfigured:	return "Audio route changed"
		case .island:		return "Dynamic Island"
		}
	}

	var symbolName: String {
		switch kind {
		case .claimed:		return "hand.raised.fill"
		case .released:		return "hand.wave"
		case .started:		return "play.circle.fill"
		case .restarted:	return "arrow.clockwise.circle.fill"
		case .stopped:		return "stop.circle"
		case .failed:		return "exclamationmark.triangle.fill"
		case .interrupted:	return "phone.down.fill"
		case .resumed:		return "phone.fill"
		case .reconfigured:	return "airpods"
		case .island:		return "platter.filled.top.iphone"
		}
	}

	var tint: Color {
		switch kind {
		case .started, .restarted, .resumed:	return .green
		case .failed:							return .red
		case .interrupted:						return .orange
		case .stopped, .released:				return .secondary
		case .claimed, .reconfigured, .island:	return .accentColor
		}
	}
}

final class BackgroundAudioStatus: ObservableObject {
	static let shared = BackgroundAudioStatus()

	// Enough to cover a long bulk install without growing without bound. The
	// interesting events are always the recent ones.
	private static let _maxEvents = 250

	/// Whether the silent audio graph is actually running right now.
	@Published private(set) var isRunning: Bool = false

	/// Human-readable names of whatever is currently holding a claim.
	@Published private(set) var owners: [String] = []

	/// Oldest first. The log view reverses this for display.
	@Published private(set) var events: [BackgroundAudioEvent] = []

	private init() { }

	// MARK: - Reporting (called from BackgroundAudioManager)

	// `DispatchQueue.main.async` rather than `Task { @MainActor in }`: dispatch
	// is FIFO, unstructured tasks are not, and a log that reorders itself is
	// worse than no log. The callers may be holding the manager's lock, so this
	// has to stay async — never sync — to avoid deadlocking against it.
	func update(isRunning: Bool, owners: [String]) {
		// Feed ActivityKit immediately from the manager's current worker queue.
		// The visible badge still publishes on main, but Live Activity ownership
		// must not sit behind a suspended or heavily-throttled UI run loop while
		// the signing/install workers continue in the background.
		if #available(iOS 16.2, *) {
			KeepAliveActivityController.shared.sync(isRunning: isRunning, owners: owners)
		}

		DispatchQueue.main.async {
			if self.isRunning != isRunning { self.isRunning = isRunning }
			if self.owners != owners { self.owners = owners }
		}
	}

	func record(_ kind: BackgroundAudioEvent.Kind, _ detail: String = "") {
		// Timestamp at the moment it happened, not at the moment main gets to it.
		let event = BackgroundAudioEvent(date: Date(), kind: kind, detail: detail)

		DispatchQueue.main.async {
			self.events.append(event)

			if self.events.count > Self._maxEvents {
				self.events.removeFirst(self.events.count - Self._maxEvents)
			}
		}
	}

	// MARK: - UI actions

	func clear() {
		DispatchQueue.main.async { self.events.removeAll() }
	}

	func exportToText() -> String {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

		var text = "Ksign Background Audio Log\n"
		text += "Exported: \(formatter.string(from: Date()))\n"
		text += "State: \(isRunning ? "playing silent audio" : "not playing")\n"
		text += "Held by: \(owners.isEmpty ? "nothing" : owners.joined(separator: ", "))\n"
		text += String(repeating: "=", count: 30) + "\n\n"

		for event in events {
			let line = event.detail.isEmpty
				? event.title
				: "\(event.title) — \(event.detail)"

			text += "[\(formatter.string(from: event.date))] \(line)\n"
		}

		return text
	}
}

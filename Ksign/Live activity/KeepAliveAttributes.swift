//
//  KeepAliveAttributes.swift
//  Ksign
//

import ActivityKit
import Foundation

// The shape of the keep-alive Live Activity, shared by the app (which starts
// and updates it) and the widget extension (which draws it).
//
// This file is compiled into both targets. ActivityKit matches an activity to
// its UI by attributes type, so the two sides have to agree exactly — if you
// add a field here, both targets pick it up from this one file rather than
// from two copies that can drift.
//
// There is deliberately no progress in here. This is a status display, not a
// job: it says whether the silent audio is up and what's holding it, the same
// way a weather activity says what the temperature is without anything ever
// being "complete". That's the difference between this and the download pill,
// which really is finite work with a percentage.
@available(iOS 16.2, *)
struct KeepAliveAttributes: ActivityAttributes {
	struct ContentState: Codable, Hashable {
		// Whether the audio graph is actually running, not merely claimed.
		// These come apart exactly when something has gone wrong, which is the
		// case worth being able to see from outside the app.
		var isRunning: Bool

		// Display names of whatever currently holds a claim — "Signing",
		// "Bulk installs". Empty is possible for a moment during the linger
		// window after the last release.
		var owners: [String]

		// What the compact trailing slot shows. Kept short on purpose; there
		// is very little room next to the camera.
		var shortLabel: String {
			owners.first ?? (isRunning ? "Awake" : "Idle")
		}

		var summary: String {
			owners.isEmpty
				? (isRunning ? "Winding down" : "Nothing to keep awake")
				: owners.joined(separator: ", ")
		}

		var statusText: String {
			isRunning ? "Silent audio on" : "Silent audio off"
		}
	}

	// Static for the life of the activity. Only here because ActivityAttributes
	// wants at least one stored property, and a start time is the one thing
	// that genuinely doesn't change.
	var startedAt: Date
}

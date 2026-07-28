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

		// Batch position, when the owner knows one. Signing, bulk installs,
		// bulk export and batch import all count apps, so they fill these in;
		// anything else leaves them nil and the bar is simply absent rather
		// than sitting at zero pretending to be stuck.
		var completed: Int?
		var total: Int?

		// A real 0–1 figure when the owner has one. Installs do —
		// `aggregateProgress` already blends each job's `overallProgress` — and
		// it's far better than the app count, which only moves in whole steps
		// and so barely moves at all when one app takes most of the batch.
		var progressFraction: Double?

		// The phase the work is actually in, straight from the state the app
		// already keeps: "Sending Manifest", "Installing", "Modifying". Nil when
		// the owner has no phase worth naming.
		var detail: String?

		// What the compact trailing slot shows. Kept short on purpose; there
		// is very little room next to the camera.
		var shortLabel: String {
			owners.first ?? (isRunning ? "Awake" : "Idle")
		}

		// The compact trailing slot is only a few characters wide, so it shows
		// the batch position when there is one — "3/12" beats "Signing" once
		// you already know what you started.
		var compactTrailingLabel: String {
			if let total, total > 0, let completed {
				return "\(min(completed, total))/\(total)"
			}
			return shortLabel
		}

		var summary: String {
			owners.isEmpty
				? (isRunning ? "Winding down" : "Nothing to keep awake")
				: owners.joined(separator: ", ")
		}

		// "Bulk installs · Sending Manifest" — what's holding the keep-alive
		// and what it's doing right now, on one line.
		var summaryLine: String {
			guard let detail, !detail.isEmpty else { return summary }
			return "\(summary) · \(detail)"
		}

		var statusText: String {
			isRunning ? "Silent audio on" : "Silent audio off"
		}

		// Reassurance line. The whole reason this pill exists is that you've
		// left the app and want to know it's still working, so say that.
		var reassurance: String {
			isRunning
				? "ASign will finish in the background"
				: "Not holding the app awake — work may pause"
		}

		// Prefer a real fraction; fall back to the app count only when that's
		// all there is. nil means there's nothing meaningful to draw and the
		// bar is left out entirely.
		var fraction: Double? {
			if let progressFraction {
				return min(1, max(0, progressFraction))
			}

			guard let total, total > 0, let completed else { return nil }
			return min(1, max(0, Double(completed) / Double(total)))
		}

		var countLabel: String? {
			guard let total, total > 0, let completed else { return nil }
			return "\(min(completed, total)) of \(total)"
		}
	}

	// Static for the life of the activity. Only here because ActivityAttributes
	// wants at least one stored property, and a start time is the one thing
	// that genuinely doesn't change.
	var startedAt: Date
}

//
//  KeepAliveAttributes.swift
//  Ksign
//

import ActivityKit
import Foundation

// Shared ActivityKit state. This file is compiled into both the app and widget
// targets, so every field must remain identical on both sides.
@available(iOS 16.2, *)
struct KeepAliveAttributes: ActivityAttributes {
	struct ContentState: Codable, Hashable {
		// Whether the silent-audio graph is actually running, not merely claimed.
		var isRunning: Bool

		// Display names of the current keep-alive owners. The focused owner is first.
		var owners: [String]

		// Whole-item batch position, when one exists.
		var completed: Int?
		var total: Int?

		// A genuine 0...1 progress value. Installs provide this continuously; other
		// operations fall back to the completed/total count.
		var progressFraction: Double?

		// Current work phase and when that phase began. The widget renders the date
		// as an elapsed timer without requiring per-second app updates.
		var detail: String?
		var detailStartedAt: Date?

		var shortLabel: String {
			owners.first ?? (isRunning ? "Awake" : "Idle")
		}

		var compactTrailingLabel: String {
			if let progressFraction {
				return "\(Int((min(1, max(0, progressFraction)) * 100).rounded()))%"
			}
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

		var summaryLine: String {
			guard let detail, !detail.isEmpty else { return summary }
			return "\(summary) · \(detail)"
		}

		var statusText: String {
			isRunning ? "Silent audio on" : "Silent audio off"
		}

		var reassurance: String {
			isRunning
				? "ASign will finish in the background"
				: "Not holding the app awake — work may pause"
		}

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

		var percentageLabel: String? {
			guard let progressFraction else { return nil }
			let value = Int((min(1, max(0, progressFraction)) * 100).rounded())
			return "\(value)%"
		}

		var progressSummaryLabel: String? {
			switch (countLabel, percentageLabel) {
			case let (count?, percentage?): return "\(count) · \(percentage)"
			case let (count?, nil): return count
			case let (nil, percentage?): return percentage
			default: return nil
			}
		}
	}

	var startedAt: Date
}

//
//  KeepAliveLiveActivity.swift
//  KsignLiveActivity
//

import ActivityKit
import SwiftUI
import WidgetKit

// The Dynamic Island and Lock Screen presentations of the keep-alive.
//
// The bar only appears when the owner actually counts apps — signing, bulk
// installs, bulk export and batch import all do. Anything else leaves it out
// entirely rather than showing an empty bar, which reads as stuck rather than
// as absent.
//
// Note there is no bar in the compact presentation, and there can't be: compact
// leading and compact trailing are two separate views sitting either side of
// the TrueDepth camera, so nothing can span the gap between them. The counts go
// in the trailing slot instead, where there's room for "3/12".
struct KeepAliveLiveActivity: Widget {
	var body: some WidgetConfiguration {
		ActivityConfiguration(for: KeepAliveAttributes.self) { context in
			_DetailView(state: context.state)
				.padding()
				.activityBackgroundTint(Color.black.opacity(0.55))
				.activitySystemActionForegroundColor(.primary)
		} dynamicIsland: { context in
			DynamicIsland {
				DynamicIslandExpandedRegion(.leading) {
					_Symbol(isRunning: context.state.isRunning)
						.font(.title3)
						.padding(.leading, 6)
				}

				DynamicIslandExpandedRegion(.trailing) {
					Text(context.state.isRunning ? "Awake" : "Not awake")
						.font(.caption)
						.foregroundStyle(context.state.isRunning ? .green : .orange)
						.padding(.trailing, 6)
				}

				DynamicIslandExpandedRegion(.bottom) {
					// The horizontal padding is load-bearing. Without it the
					// leading edge of this region runs under the Island's
					// rounded corner and the first character of the owner name
					// gets sliced off — "Import" rendering as "'mport".
					_DetailView(state: context.state)
						.padding(.horizontal, 6)
						.padding(.top, 2)
				}
			} compactLeading: {
				_Symbol(isRunning: context.state.isRunning)
			} compactTrailing: {
				// Whichever is more useful in the very small space available:
				// the batch position if there is one, otherwise who's holding
				// the keep-alive.
				Text(context.state.compactTrailingLabel)
					.font(.caption2)
					.monospacedDigit()
					.lineLimit(1)
					.foregroundStyle(.secondary)
			} minimal: {
				_Symbol(isRunning: context.state.isRunning)
			}
			.keylineTint(context.state.isRunning ? .green : .orange)
		}
	}
}

private struct _Symbol: View {
	let isRunning: Bool

	var body: some View {
		Image(systemName: isRunning ? "speaker.wave.2.fill" : "speaker.slash.fill")
			.foregroundStyle(isRunning ? .green : .orange)
	}
}

// Shared by the expanded Island and the Lock Screen so the two can't drift.
private struct _DetailView: View {
	let state: KeepAliveAttributes.ContentState

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(alignment: .firstTextBaseline) {
				Text(state.statusText)
					.font(.subheadline.weight(.semibold))

				Spacer(minLength: 8)

				if let countLabel = state.countLabel {
					Text(countLabel)
						.font(.caption)
						.monospacedDigit()
						.foregroundStyle(.secondary)
						// Counts tick upward one app at a time, so animate the
						// digits rather than having them snap.
						.contentTransition(.numericText())
				}
			}

			if let fraction = state.fraction {
				ProgressView(value: fraction)
					.progressViewStyle(.linear)
					.tint(state.isRunning ? .green : .orange)
			}

			// "Bulk installs · Sending Manifest"
			Text(state.summaryLine)
				.font(.caption.weight(.medium))
				.lineLimit(1)
				.contentTransition(.opacity)

			Text(state.reassurance)
				.font(.caption2)
				.foregroundStyle(.secondary)
				.lineLimit(2)
				.fixedSize(horizontal: false, vertical: true)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

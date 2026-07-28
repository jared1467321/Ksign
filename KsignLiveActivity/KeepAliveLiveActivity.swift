//
//  KeepAliveLiveActivity.swift
//  KsignLiveActivity
//

import ActivityKit
import SwiftUI
import WidgetKit

// The Dynamic Island and Lock Screen presentations of the keep-alive.
//
// There is no progress here on purpose. This reports a state — the silent audio
// is up, and here is what's holding it — the way a weather activity reports a
// temperature. Nothing is ever "complete", so nothing pretends to be.
//
// The system requires all four presentations to exist. Compact is what you'll
// normally see; minimal is what you get when something else is also running an
// activity; expanded appears on long press.
struct KeepAliveLiveActivity: Widget {
	var body: some WidgetConfiguration {
		ActivityConfiguration(for: KeepAliveAttributes.self) { context in
			_LockScreenView(state: context.state)
				.activityBackgroundTint(Color.black.opacity(0.55))
				.activitySystemActionForegroundColor(.primary)
		} dynamicIsland: { context in
			DynamicIsland {
				DynamicIslandExpandedRegion(.leading) {
					_Symbol(isRunning: context.state.isRunning)
						.font(.title3)
						.padding(.leading, 4)
				}

				DynamicIslandExpandedRegion(.trailing) {
					Text(context.state.isRunning ? "Awake" : "Not awake")
						.font(.caption)
						.foregroundStyle(context.state.isRunning ? .green : .orange)
						.padding(.trailing, 4)
				}

				DynamicIslandExpandedRegion(.bottom) {
					VStack(alignment: .leading, spacing: 3) {
						Text(context.state.statusText)
							.font(.subheadline.weight(.medium))

						Text(context.state.summary)
							.font(.caption)
							.foregroundStyle(.secondary)
							.lineLimit(2)
					}
					.frame(maxWidth: .infinity, alignment: .leading)
				}
			} compactLeading: {
				_Symbol(isRunning: context.state.isRunning)
			} compactTrailing: {
				// Very little room next to the camera, so this is the single
				// most useful word: who's holding it.
				Text(context.state.shortLabel)
					.font(.caption2)
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

private struct _LockScreenView: View {
	let state: KeepAliveAttributes.ContentState

	var body: some View {
		HStack(spacing: 12) {
			_Symbol(isRunning: state.isRunning)
				.font(.title2)

			VStack(alignment: .leading, spacing: 3) {
				Text(state.statusText)
					.font(.subheadline.weight(.medium))

				Text(state.summary)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(2)
			}

			Spacer(minLength: 0)
		}
		.padding()
	}
}

//
//  KeepAliveLiveActivity.swift
//  KsignLiveActivity
//

import ActivityKit
import SwiftUI
import WidgetKit

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
					_DetailView(state: context.state)
						.padding(.horizontal, 6)
						.padding(.top, 2)
				}
			} compactLeading: {
				_Symbol(isRunning: context.state.isRunning)
			} compactTrailing: {
				Group {
					if context.state.progressFraction != nil {
						Text(context.state.compactTrailingLabel)
					} else if context.state.detail != nil, let startedAt = context.state.detailStartedAt {
						// A system-rendered timer keeps visibly advancing even when the
						// current signing/import phase has no measurable sub-progress.
						Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
					} else {
						Text(context.state.compactTrailingLabel)
					}
				}
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

private struct _DetailView: View {
	let state: KeepAliveAttributes.ContentState

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(alignment: .firstTextBaseline) {
				Text(state.statusText)
					.font(.subheadline.weight(.semibold))

				Spacer(minLength: 8)

				if let progressLabel = state.progressSummaryLabel {
					Text(progressLabel)
						.font(.caption)
						.monospacedDigit()
						.foregroundStyle(.secondary)
						.contentTransition(.numericText())
				}
			}

			if let fraction = state.fraction {
				ProgressView(value: fraction)
					.progressViewStyle(.linear)
					.tint(state.isRunning ? .green : .orange)
			}

			HStack(spacing: 8) {
				Text(state.summaryLine)
					.font(.caption.weight(.medium))
					.lineLimit(1)
					.contentTransition(.opacity)

				Spacer(minLength: 4)

				if state.detail != nil, let startedAt = state.detailStartedAt {
					Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
						.font(.caption2)
						.monospacedDigit()
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
			}

			Text(state.reassurance)
				.font(.caption2)
				.foregroundStyle(.secondary)
				.lineLimit(2)
				.fixedSize(horizontal: false, vertical: true)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

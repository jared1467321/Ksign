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
                .activityBackgroundTint(Color(context.state.theme.background))
                .activitySystemActionForegroundColor(Color(context.state.theme.actionText))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    _Symbol(state: context.state)
                        .font(.title3)
                        .padding(.leading, 6)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.isRunning ? "Awake" : "Not awake")
                        .font(.caption)
                        .foregroundStyle(_statusColor(context.state))
                        .padding(.trailing, 6)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    _DetailView(state: context.state)
                        .padding(.horizontal, 6)
                        .padding(.top, 2)
                }
            } compactLeading: {
                _Symbol(state: context.state)
            } compactTrailing: {
                Text(context.state.compactTrailingLabel)
                    .font(.caption2)
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(Color(context.state.theme.secondaryText))
            } minimal: {
                _Symbol(state: context.state)
            }
            .keylineTint(_statusColor(context.state))
        }
    }
}

private struct _Symbol: View {
    let state: KeepAliveAttributes.ContentState

    var body: some View {
        Image(systemName: state.isRunning ? "speaker.wave.2.fill" : "speaker.slash.fill")
            .foregroundStyle(_statusColor(state))
    }
}

private struct _DetailView: View {
    let state: KeepAliveAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(state.theme.primaryText))

                Spacer(minLength: 8)

                if let progressLabel = state.progressSummaryLabel {
                    Text(progressLabel)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color(state.theme.secondaryText))
                        .contentTransition(.numericText())
                }
            }

            if let fraction = state.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(_statusColor(state))
            }

            HStack(spacing: 8) {
                Text(state.summaryLine)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color(state.theme.primaryText))
                    .lineLimit(1)
                    .contentTransition(.opacity)

                Spacer(minLength: 4)

                if state.detail != nil, let startedAt = state.detailStartedAt {
                    Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(Color(state.theme.secondaryText))
                        .lineLimit(1)
                }
            }

            Text(state.reassurance)
                .font(.caption2)
                .foregroundStyle(Color(state.theme.secondaryText))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func _statusColor(_ state: KeepAliveAttributes.ContentState) -> Color {
    Color(state.isRunning ? state.theme.running : state.theme.idle)
}

private extension Color {
    init(_ value: KeepAliveThemeColor) {
        self.init(
            .sRGB,
            red: value.red,
            green: value.green,
            blue: value.blue,
            opacity: value.alpha
        )
    }
}

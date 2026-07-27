//
//  BackgroundAudioIndicatorView.swift
//  Ksign
//

import SwiftUI

// The speaker badge that sits at the top of the window. 🔊 while the silent
// keep-alive is actually running, 🔇 while it isn't, and a tap opens the log of
// how it got that way.
//
// It reads `isRunning` — the real engine state, republished on every health
// check — rather than whether anything is claimed. Those differ exactly when
// something has gone wrong, which is the case worth being able to see.
struct BackgroundAudioIndicatorView: View {
	@ObservedObject private var _status = BackgroundAudioStatus.shared
	@State private var _showingLog = false

	var body: some View {
		Button {
			_showingLog = true
		} label: {
			Text(verbatim: _status.isRunning ? "🔊" : "🔇")
				.font(.system(size: 15))
				.padding(.horizontal, 12)
				.padding(.vertical, 4)
				.background(
					Capsule()
						.fill(Color(uiColor: .secondarySystemBackground))
				)
				.overlay(
					Capsule()
						.strokeBorder(
							_status.isRunning ? Color.green.opacity(0.6) : Color.clear,
							lineWidth: 1
						)
				)
				.contentShape(Capsule())
		}
		.buttonStyle(.plain)
		.animation(.easeInOut(duration: 0.25), value: _status.isRunning)
		.accessibilityLabel(_status.isRunning
			? "Keep-alive running. Tap for details."
			: "Keep-alive idle. Tap for details.")
		.sheet(isPresented: $_showingLog) {
			BackgroundAudioLogView(status: _status)
		}
	}
}

struct BackgroundAudioLogView: View {
	@ObservedObject var status: BackgroundAudioStatus
	@Environment(\.dismiss) private var _dismiss

	private static let _timeFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm:ss"
		return formatter
	}()

	var body: some View {
		NavigationStack {
			List {
				Section {
					HStack(spacing: 12) {
						Text(verbatim: status.isRunning ? "🔊" : "🔇")
							.font(.system(size: 26))

						VStack(alignment: .leading, spacing: 3) {
							Text(status.isRunning ? "Playing silent audio" : "Not playing")
								.font(.subheadline.weight(.medium))

							Text(_stateDescription)
								.font(.caption)
								.foregroundColor(.secondary)
								.fixedSize(horizontal: false, vertical: true)
						}
					}
					.padding(.vertical, 4)
				}

				Section {
					if status.events.isEmpty {
						Text("Nothing yet. Start an install or a download and the keep-alive's comings and goings will show up here.")
							.font(.footnote)
							.foregroundColor(.secondary)
					} else {
						// Newest first: in a sheet you opened because something
						// looked wrong, the thing that just happened is the
						// thing you want.
						ForEach(status.events.reversed()) { event in
							_row(for: event)
						}
					}
				} header: {
					Text("History")
				}
			}
			.navigationTitle("Keep-Alive")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button("Done") { _dismiss() }
				}

				ToolbarItemGroup(placement: .navigationBarTrailing) {
					ShareLink(item: status.exportToText()) {
						Image(systemName: "square.and.arrow.up")
					}
					.disabled(status.events.isEmpty)

					Button {
						status.clear()
					} label: {
						Image(systemName: "trash")
					}
					.disabled(status.events.isEmpty)
				}
			}
		}
	}

	private var _stateDescription: String {
		if !status.owners.isEmpty {
			return "Held by " + status.owners.joined(separator: ", ")
		}

		if !OptionsManager.shared.options.backgroundAudio {
			return "Background audio is turned off in Settings › Features"
		}

		// The linger window in BackgroundAudioManager. Brief, but without a
		// word for it the badge reads 🔊 with nothing listed and looks stuck.
		if status.isRunning {
			return "Winding down — nothing is claimed, stopping in a moment"
		}

		return "Nothing needs the app kept awake right now"
	}

	private func _row(for event: BackgroundAudioEvent) -> some View {
		HStack(alignment: .top, spacing: 10) {
			Image(systemName: event.symbolName)
				.font(.system(size: 13))
				.foregroundColor(event.tint)
				.frame(width: 18)
				.padding(.top, 2)

			VStack(alignment: .leading, spacing: 2) {
				Text(event.title)
					.font(.subheadline)

				if !event.detail.isEmpty {
					Text(event.detail)
						.font(.caption)
						.foregroundColor(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}

			Spacer(minLength: 8)

			Text(Self._timeFormatter.string(from: event.date))
				.font(.system(size: 11, design: .monospaced))
				.foregroundColor(.secondary)
				.padding(.top, 2)
		}
		.padding(.vertical, 2)
	}
}

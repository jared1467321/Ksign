//
//  InstallDrawerView.swift
//  Ksign
//

import SwiftUI
import IDeviceSwift
import NimbleViews

// Hosts the install drawer at the tab bar root.
//
// This went through a hand-built drag drawer and came back to a plain `.sheet`,
// which is the right call now: a sheet is UIKit-backed, so the drag is smooth
// and it looks like the rest of the system for free. The two things a sheet
// couldn't do before — survive dismissal, and exist outside `LibraryView` —
// aren't its problem any more. The installs live in `InstallSession`, and this
// host sits above the tab bar rather than inside one tab.
//
// Dismiss it and a pill appears above the tab bar to bring it back.
struct InstallDrawerView: View {
	@ObservedObject private var session = InstallSession.shared

	// How far above the tab bar the pill floats. The only number here likely
	// to want nudging between the iOS 18 and pre-18 tab bars.
	private let _tabBarInset: CGFloat = 58

	var body: some View {
		// Nothing but the pill is hit-testable, so the tab bar underneath stays
		// tappable. The previous version clipped an oversized drawer down to a
		// lip — but clipping only changes what's *drawn*, not what receives
		// touches, so the invisible remainder was swallowing every tab tap.
		ZStack(alignment: .bottom) {
			if session.isActive, !session.isDrawerPresented {
				_pill
					.padding(.bottom, _tabBarInset)
					.transition(.move(edge: .bottom).combined(with: .opacity))
			}
		}
		.animation(.easeInOut(duration: 0.25), value: session.isDrawerPresented)
		.animation(.easeInOut(duration: 0.25), value: session.isActive)
		.sheet(isPresented: $session.isDrawerPresented) {
			InstallDrawerSheet()
				.presentationDetents([.medium, .large])
				.presentationDragIndicator(.visible)
		}
	}

	private var _pill: some View {
		Button {
			session.isDrawerPresented = true
		} label: {
			HStack(spacing: 10) {
				ZStack {
					Circle()
						.stroke(Color.secondary.opacity(0.25), lineWidth: 3)

					Circle()
						.trim(from: 0, to: max(0.02, session.aggregateProgress))
						.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
						.rotationEffect(.degrees(-90))
				}
				.frame(width: 18, height: 18)

				// Spelled out as `String.localized` rather than `.localized`:
				// both `String` and `LocalizedStringKey` offer it, and inside a
				// ternary feeding an overloaded `Text` init that's more than
				// the type checker should have to guess at.
				Text(session.isPaused
					 ? String.localized("Paused")
					 : "\(session.completedCount) of \(session.totalCount) installed")
					.font(.footnote.weight(.medium))
					.foregroundStyle(.primary)

				Image(systemName: "chevron.up")
					.font(.caption2.weight(.bold))
					.foregroundStyle(.secondary)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 11)
			.background(.regularMaterial, in: Capsule())
			.overlay(
				Capsule()
					.stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
			)
			.shadow(color: Color.black.opacity(0.16), radius: 10, y: 3)
		}
		.buttonStyle(.plain)
	}
}

// The sheet's contents. Deliberately close to what was here before the drawer
// experiment — a titled card of app icons — because that's what looked right.
struct InstallDrawerSheet: View {
	@ObservedObject private var session = InstallSession.shared

	var body: some View {
		VStack(spacing: 0) {
			VStack(spacing: 8) {
				HStack(spacing: 14) {
					Text(_title)
						.font(.headline)

					Spacer(minLength: 0)

					// Hidden once nothing is running — there'd be nothing left
					// to pause.
					if !_isSettled {
						Button {
							session.togglePause()
						} label: {
							Image(systemName: session.isPaused ? "play.circle.fill" : "pause.circle.fill")
								.font(.title3)
								.foregroundStyle(session.isPaused ? Color.accentColor : Color.secondary)
						}
						.buttonStyle(.plain)
					}

					if _isSettled {
						Button {
							session.dismissAll()
						} label: {
							Image(systemName: "xmark.circle.fill")
								.font(.title3)
								.foregroundStyle(.secondary)
						}
						.buttonStyle(.plain)
					}
				}

				HStack(spacing: 10) {
					ProgressView(value: session.aggregateProgress)
						.progressViewStyle(.linear)

					Text("\(session.completedCount)/\(session.totalCount)")
						.font(.caption.monospacedDigit())
						.foregroundStyle(.secondary)
				}

				if session.isPaused, session.waitingCount > 0 {
					HStack {
						Text("\(session.waitingCount) waiting")
							.font(.caption)
							.foregroundStyle(.secondary)

						Spacer(minLength: 0)
					}
				}
			}
			.padding(.horizontal, 20)
			.padding(.top, 22)
			.padding(.bottom, 14)

			ScrollView {
				BulkInstallPreviewView(
					jobs: session.jobs,
					originalCount: session.totalCount
				)
				.padding(.bottom, 20)
			}
		}
		// Nested inside the drawer, the way it used to be nested inside the row.
		.sheet(item: $session.webviewJob) { job in
			SafariRepresentableView(url: job.installer.pageEndpoint)
				.ignoresSafeArea()
		}
	}

	// True once nothing is still working — i.e. everything left failed. That's
	// the only time offering a close button makes sense.
	private var _isSettled: Bool {
		!session.jobs.isEmpty && session.jobs.allSatisfy { $0.phase == .failed }
	}

	private var _title: String {
		if _isSettled { return .localized("Install Failed") }
		return session.isPaused
			? .localized("Paused")
			: .localized("Installing")
	}
}

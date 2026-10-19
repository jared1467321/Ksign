//
//  InstallDrawerView.swift
//  Ksign
//

import SwiftUI
import NimbleExtensions
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
			if session.isDrawerAvailable, !session.isDrawerPresented {
				_pill
					.padding(.bottom, _tabBarInset)
					.transition(.move(edge: .bottom).combined(with: .opacity))
			}
		}
		.animation(.easeInOut(duration: 0.25), value: session.isDrawerPresented)
		.animation(.easeInOut(duration: 0.25), value: session.isDrawerAvailable)
		.sheet(isPresented: $session.isDrawerPresented) {
			InstallDrawerSheet()
				.nbThemeGlassSheet()
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
						.nbThemeStroke(.textSecondary, opacity: 0.25, lineWidth: 3)
                        .nbThemePaintLayer(0)

					Circle()
						.trim(from: 0, to: max(0.02, session.aggregateProgress))
						.nbThemeStroke(.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
						.rotationEffect(.degrees(-90))
                        .nbThemePaintLayer(1)
				}
                .nbThemePaintGroup()
				.frame(width: 18, height: 18)

				// Spelled out as `String.localized` rather than `.localized`:
				// both `String` and `LocalizedStringKey` offer it, and inside a
				// ternary feeding an overloaded `Text` init that's more than
				// the type checker should have to guess at.
				Text(session.isPaused
					 ? String.localized("Paused")
					 : "\(session.completedCount) of \(session.totalCount) installed")
					.font(.footnote.weight(.medium))
					.nbThemeForeground(.text)

				Image(systemName: "chevron.up")
					.font(.caption2.weight(.bold))
					.nbThemeForeground(.textSecondary)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 11)
			.nbThemeBackground(.overlaySurface, in: Capsule())
			.nbThemeOverlay(
				Capsule()
					.nbThemeStroke(.text, opacity: 0.08, lineWidth: 0.5)
			)
			.nbThemeShadow(.shadow, radius: 10, y: 3)
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
								.nbThemeForeground(session.isPaused ? .accent : .textSecondary)
						}
						.buttonStyle(.plain)
						.accessibilityLabel(session.isPaused ? String.localized("Resume") : String.localized("Pause"))
					}

					if _isSettled {
						Button {
							session.dismissAll()
						} label: {
							Image(systemName: "xmark.circle.fill")
								.font(.title3)
								.nbThemeForeground(.textSecondary)
						}
						.buttonStyle(.plain)
						.accessibilityLabel(String.localized("Close"))
						.disabled(session.hasWorkInProgress)
					}
				}

				HStack(spacing: 10) {
					ProgressView(value: session.aggregateProgress)
					.nbThemeTint(.accent)
						.progressViewStyle(.linear)

					// Installing right now over apps still on the drawer, not
					// finished over batch size. The bar beside it still
					// measures the whole batch, so the two aren't reading the
					// same thing — this one answers "what's left", the bar
					// answers "how far in".
					Text("\(session.runningCount)/\(session.remainingCount)")
						.font(.caption.monospacedDigit())
						.nbThemeForeground(.textSecondary)
				}

				if session.isPaused, session.waitingCount > 0 {
					HStack {
						Text("\(session.waitingCount) waiting")
							.font(.caption)
							.nbThemeForeground(.textSecondary)

						Spacer(minLength: 0)
					}
				}

				Text("\(session.completedCount) of \(session.totalCount) installed")
					.font(.caption.monospacedDigit())
					.nbThemeForeground(.textSecondary)
				if session.skippedCount > 0 {
					Text("\(session.skippedCount) skipped · Hold a skipped app for details")
						.font(.caption)
						.nbThemeForeground(.warning)
				}

				if session.usesNativeInstallLimit {
					NativeInstallLimitControl()
				}

				if session.isPaused || _isSettled {
					if session.hasWorkInProgress {
						Text("Waiting for current work to finish…")
							.font(.caption)
							.nbThemeForeground(.textSecondary)
					}

					Button {
						session.cancelAndSelectInstalled()
					} label: {
						Label(
							_isSettled ? String.localized("Select Installed Apps") : String.localized("Cancel Task & Select Installed"),
							systemImage: "checkmark.circle"
						)
						.frame(maxWidth: .infinity)
					}
					.buttonStyle(.bordered)
					.nbThemeTint(.accent)
					.disabled(!session.canCancelAndSelectInstalled)
				}

				// Only while paused, and only when there's a manifest to reset:
				// sends whatever's stuck (at the prompt, or stuck mid-install and
				// never reported back) to the ready pool. Resume rebuilds a fresh
				// manifest from the pool.
				if session.isPaused, session.hasInFlightGroup {
					Button {
						session.clearStuckManifest()
					} label: {
						Label(String.localized("Clear stuck installs"), systemImage: "arrow.uturn.backward.circle")
							.font(.caption.weight(.medium))
							.frame(maxWidth: .infinity)
					}
					.buttonStyle(.bordered)
					.controlSize(.small)
					.nbThemeTint(.accent)
					.padding(.top, 2)
				}
			}
			.padding(.horizontal, 20)
			.padding(.top, 22)
			.padding(.bottom, 14)

			InstallDrawerApps()
				.equatable()
		}
		.nbThemeCanvas()
		// Nested inside the drawer, the way it used to be nested inside the row.
		.sheet(item: $session.webviewJob) { job in
			// The server is built lazily now, so this is only reachable once
			// the job holds a slot and has one.
			if let installer = job.installer {
				SafariRepresentableView(url: installer.pageEndpoint)
					.ignoresSafeArea()
			}
		}
	}

	// Results remain available after successful rows retire, including when
	// some apps failed and others installed successfully.
	private var _isSettled: Bool {
		session.isFinished
	}

	private var _title: String {
		if _isSettled {
			if session.jobs.contains(where: { $0.phase == .failed }) { return .localized("Finished with Errors") }
			return session.skippedCount > 0 ? .localized("Finished with Skips") : .localized("Installed")
		}
		return session.isPaused
			? .localized("Paused")
			: .localized("Installing")
	}
}

private struct NativeInstallLimitControl: View {
	@ObservedObject private var session = InstallSession.shared
	@State private var text = ""
	@FocusState private var isEditing: Bool

	var body: some View {
		HStack(spacing: 10) {
			Text("Active app limit")
				.font(.caption)
				.nbThemeForeground(.textSecondary)
			Spacer(minLength: 0)
			TextField("1–100", text: $text)
				.keyboardType(.numberPad)
				.multilineTextAlignment(.center)
				.font(.subheadline.monospacedDigit())
				.frame(width: 48)
				.padding(.horizontal, 8)
				.padding(.vertical, 8)
				.nbThemeBackground(.controlFill, in: RoundedRectangle(cornerRadius: 8))
				.focused($isEditing)
				.accessibilityLabel("Maximum active apps")
				.onSubmit { isEditing = false }
			VStack(spacing: 0) {
				Button { adjust(by: 1) } label: {
					Image(systemName: "chevron.up")
						.frame(width: 32, height: 22)
						.contentShape(Rectangle())
				}
				.disabled(session.nativeInstallLimit >= NativeInstallLimit.allowedValues.upperBound)
				.accessibilityLabel("Increase active app limit")
				Button { adjust(by: -1) } label: {
					Image(systemName: "chevron.down")
						.frame(width: 32, height: 22)
						.contentShape(Rectangle())
				}
				.disabled(session.nativeInstallLimit <= NativeInstallLimit.allowedValues.lowerBound)
				.accessibilityLabel("Decrease active app limit")
			}
			.font(.caption.weight(.semibold))
			.buttonStyle(.plain)
			.nbThemeForeground(.accent)
		}
		.onAppear { text = String(session.nativeInstallLimit) }
		.onChange(of: text) { value in
			if let limit = NativeInstallLimit.enteredValue(value) {
				session.setNativeInstallLimit(limit)
				if value != String(limit) { text = String(limit) }
			}
		}
		.onChange(of: session.nativeInstallLimit) { value in
			if !isEditing { text = String(value) }
		}
		.onChange(of: isEditing) { editing in
			if !editing { text = String(session.nativeInstallLimit) }
		}
		.toolbar {
			ToolbarItemGroup(placement: .keyboard) {
				Spacer()
				Button("Done") { isEditing = false }
			}
		}
	}

	private func adjust(by delta: Int) {
		session.setNativeInstallLimit(session.nativeInstallLimit + delta)
		text = String(session.nativeInstallLimit)
	}
}

// Header progress cannot invalidate the scroll contents. This wrapper has no
// changing inputs, so its equality check is constant-time. Descendants receive
// their own membership, connection and per-job events independently.
private struct InstallDrawerApps: View, Equatable {
	var body: some View {
		ScrollView {
			VPNReconnectBannerView()
				.padding(.horizontal, 20)
			DeviceConnectionSetupView()
				.padding(.horizontal, 20)
				.padding(.bottom, 12)
			BulkInstallPreviewView()
				.padding(.bottom, 20)
		}
	}
}

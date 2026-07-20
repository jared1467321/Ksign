//
//  InstallDrawerView.swift
//  Ksign
//

import SwiftUI
import IDeviceSwift
import NimbleViews

// The install drawer, as a root-level overlay rather than a sheet.
//
// A `.sheet` can't do what's needed here: it's modal (so the tab bar is
// unreachable while it's up), it only exists on the screen that presented it,
// and dismissing it destroys its content. This is a plain view sitting above
// the tab bar in a ZStack, so it persists across tabs and collapsing it to the
// lip costs nothing — the installs live in `InstallSession`, not in here.
struct InstallDrawerView: View {
	@ObservedObject private var session = InstallSession.shared

	enum Detent: CaseIterable {
		case lip, medium, large
	}

	@State private var _detent: Detent = .medium
	@State private var _drag: CGFloat = 0

	// How much of the drawer is left peeking when collapsed.
	private let _lipHeight: CGFloat = 86

	// Clearance so the lip sits *above* the tab bar rather than on top of it.
	// The iOS 18 `ExtendedTabbarView` and the older `TabbarView` aren't the
	// same height, so this is the one number to nudge if the lip looks wrong
	// on your device — everything else is driven off the safe area.
	private let _tabBarInset: CGFloat = 49

	var body: some View {
		ZStack {
			if session.isPresented, !session.jobs.isEmpty {
				_drawer
					.transition(.move(edge: .bottom))
			}
		}
		// Presented from here rather than from the row: a row can be scrolled
		// out of view or hidden behind the lip, and a sheet presented from a
		// view that isn't on screen never appears.
		.sheet(item: $session.webviewJob) { job in
			SafariRepresentableView(url: job.installer.pageEndpoint)
				.ignoresSafeArea()
		}
		.onChange(of: session.isPresented) { presented in
			if presented { _detent = .medium }
		}
	}

	private var _drawer: some View {
		GeometryReader { geo in
			let screen = geo.size.height
			let sheetHeight = max(screen * 0.92, _lipHeight)

			// Dragging down is a positive translation, so it *subtracts* from
			// how much of the drawer is showing.
			let target = _visible(_detent, screen: screen)
			let shown = min(
				_visible(.large, screen: screen),
				max(_lipHeight, target - _drag)
			)

			VStack(spacing: 0) {
				Spacer(minLength: 0)

				VStack(spacing: 0) {
					_header(screen: screen)

					Divider()
						.opacity(0.4)

					ScrollView {
						BulkInstallPreviewView(
							jobs: session.jobs,
							originalCount: session.totalCount
						)
						.padding(.vertical, 18)
					}
				}
				.background(Color(UIColor.secondarySystemBackground))
				// Two frames on purpose. The inner one keeps the contents laid
				// out at full height so the grid doesn't reflow on every frame
				// of a drag; the outer one is what's actually visible, and the
				// clip throws away the rest. Offsetting a full-height drawer
				// instead would drag its opaque body down over the tab bar.
				.frame(height: sheetHeight, alignment: .top)
				.frame(height: shown, alignment: .top)
				.clipShape(RoundedRectangle(cornerRadius: 22.5, style: .continuous))
				.shadow(color: Color.black.opacity(0.18), radius: 12, y: -2)
				.padding(.horizontal, 8)
			}
			.padding(.bottom, _tabBarInset + geo.safeAreaInsets.bottom)
		}
		.ignoresSafeArea(.keyboard)
	}

	// MARK: - Header (this is also the lip)

	private func _header(screen: CGFloat) -> some View {
		VStack(spacing: 9) {
			Capsule()
				.fill(Color.secondary.opacity(0.35))
				.frame(width: 36, height: 5)
				.padding(.top, 8)

			HStack(spacing: 12) {
				VStack(alignment: .leading, spacing: 2) {
					Text(_title)
						.font(.subheadline.weight(.semibold))

					Text("\(session.completedCount) of \(session.totalCount) installed")
						.font(.caption)
						.foregroundStyle(.secondary)
				}

				Spacer(minLength: 0)

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

			ProgressView(value: session.aggregateProgress)
				.progressViewStyle(.linear)
		}
		.padding(.horizontal, 16)
		.padding(.bottom, 12)
		// Without this the gesture only lands on the text itself.
		.contentShape(Rectangle())
		.gesture(_dragGesture(screen: screen))
		.onTapGesture {
			withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85, blendDuration: 0.2)) {
				_detent = (_detent == .lip) ? .medium : .lip
			}
		}
	}

	// MARK: - Detents

	private func _visible(_ detent: Detent, screen: CGFloat) -> CGFloat {
		switch detent {
		case .lip: return _lipHeight
		case .medium: return screen * 0.45
		case .large: return screen * 0.86
		}
	}

	private func _dragGesture(screen: CGFloat) -> some Gesture {
		DragGesture()
			.onChanged { value in
				_drag = value.translation.height
			}
			.onEnded { value in
				// Project where the drag was heading so a quick flick snaps
				// past the nearest detent rather than falling back to it.
				let projected = _visible(_detent, screen: screen) - value.predictedEndTranslation.height

				let nearest = Detent.allCases.min {
					abs(_visible($0, screen: screen) - projected)
						< abs(_visible($1, screen: screen) - projected)
				} ?? .medium

				withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85, blendDuration: 0.2)) {
					_detent = nearest
					_drag = 0
				}
			}
	}

	// MARK: - Copy

	// True once nothing is still working — i.e. everything left in the drawer
	// failed. That's the only time offering a close button makes sense.
	private var _isSettled: Bool {
		!session.jobs.isEmpty && session.jobs.allSatisfy { $0.phase == .failed }
	}

	private var _title: String {
		_isSettled
			? .localized("Install Failed")
			: .localized("Installing")
	}
}

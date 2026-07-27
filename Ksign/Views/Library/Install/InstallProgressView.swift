//
//  InstallProgressView.swift
//  Feather
//
//  Created by samara on 23.04.2025.
//

import SwiftUI
import IDeviceSwift
import NimbleExtensions

struct InstallProgressView: View {
	@State private var _isPulsing = false
	
	var app: AppInfoPresentable
	@ObservedObject var viewModel: InstallerStatusViewModel

	// How far along the pipeline this app is, for the dot only. Three states
	// rather than the old on/off flag, because "being worked on" covers two
	// visibly different things: the manifest that's installing right now, and
	// the apps building behind it for the manifest after that.
	enum Activity {
		// Sitting in the queue, not released to build yet — no dot.
		case none
		// Built or building for the *next* manifest — purple.
		case upcoming
		// Part of the manifest installing right now — orange.
		case active
	}

	// Defaults to `.none` so the single-install view — one app, nothing to
	// tell apart — is unchanged.
	var activity: Activity = .none
	
	var body: some View {
		VStack(spacing: 12) {
			_appIcon()
				.scaleEffect(_isPulsing ? 0.85 : 0.81)
				.animation(
					.easeInOut(duration: 1.0).repeatForever(autoreverses: true),
					value: _isPulsing
				)
				.onAppear { _isPulsing = true }
				// Outside the scale effect on purpose: the dot holds still
				// while the icon breathes, and it's outside the pie mask so
				// it can't be clipped by the progress fill.
				.overlay(alignment: .topTrailing) { _activityDot }
		}
	}
	
	// The pie fill alone is hard to read on light or busy artwork, so this is
	// the unambiguous "this one is going" marker: a dot wrapped in a glow that
	// pulses, so an in-progress app is easy to pick out at a glance.
	//
	// Two colours, because a grid where thirty icons all wear the same dot
	// doesn't answer the question anyone actually has — which of these is
	// happening *now*. Orange is the manifest in flight; purple is the pool
	// building behind it, which will fire as the next manifest once this one
	// clears. Undotted icons haven't been released to build at all.
	//
	// Neither one is green on purpose. Green means "done" everywhere else in
	// the app, and it's also the tint, so a green dot on a green-tinted grid
	// is the one thing here that shouldn't blend in. Orange and purple are the
	// two colours on this screen that aren't the accent.
	private var _activityDot: some View {
		let dot = activity == .upcoming ? NBHalloween.neonPurple : NBHalloween.warning
		return ZStack {
			// Soft halo that breathes in and out behind the dot.
			Circle()
				.fill(dot)
				.frame(width: 13, height: 13)
				.blur(radius: 3.5)
				.scaleEffect(_isPulsing ? 2.0 : 1.2)
				.opacity(_isPulsing ? 0.85 : 0.3)
				.animation(
					.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
					value: _isPulsing
				)

			Circle()
				.fill(dot)
				.overlay(
					Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
				)
				.frame(width: 13, height: 13)
				.shadow(color: dot.opacity(0.9), radius: 4)
		}
		.opacity(activity == .none ? 0 : 1)
		.scaleEffect(activity == .none ? 0.5 : 1)
		// Covers the purple -> orange handover as well as the fade in, so a
		// job joining the live manifest crossfades rather than snapping.
		.animation(.easeInOut(duration: 0.2), value: activity)
		// The icon is drawn at ~0.83 scale inside a 54pt box, so the box's
		// true corner sits well clear of the artwork. Nudged back in to
		// land on the edge of the circle instead of floating off it.
		.offset(x: -5, y: 5)
	}
	
	@ViewBuilder
	private func _appIcon() -> some View {
		ZStack {
			FRAppIconView(app: app)
				.opacity(_isPulsing ? 0.2 : 0.2)
				.frame(width: 54, height: 54)
				.foregroundStyle(Color.black)
			
			FRAppIconView(app: app)
				.frame(width: 54, height: 54)
				.mask(
					ZStack {
						Circle().strokeBorder(Color.white, lineWidth: 4.5)
						PieShape(progress: viewModel.overallProgress)
							.scaleEffect(viewModel.isCompleted ? 2.2 : 1)
							.animation(.smooth, value: viewModel.isCompleted)
					}
				)
				.animation(.smooth, value: viewModel.overallProgress)
		}
	}
	
	struct PieShape: Shape {
		var progress: Double
		
		func path(in rect: CGRect) -> Path {
			var path = Path()
			let center = CGPoint(x: rect.midX, y: rect.midY)
			let radius = min(rect.width, rect.height) / 2
			let startAngle = Angle(degrees: -90)
			let endAngle = Angle(degrees: -90 + progress * 360)
			
			path.move(to: center)
			path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
			path.closeSubpath()
			
			return path
		}
		
		var animatableData: Double {
			get { progress }
			set { progress = newValue }
		}
	}
}

//
//  InstallProgressView.swift
//  Feather
//
//  Created by samara on 23.04.2025.
//

import SwiftUI
import IDeviceSwift

struct InstallProgressView: View {
	@State private var _isPulsing = false
	// Drives the activity dot's heartbeat, separate from the icon's own
	// breathing so the two aren't locked in step.
	@State private var _dotPulsing = false
	
	var app: AppInfoPresentable
	@ObservedObject var viewModel: InstallerStatusViewModel
	// Whether this app is actually being worked on right now, as opposed to
	// sitting in the queue waiting for a slot. Defaults to false so the
	// single-install view — one app, nothing to tell apart — is unchanged.
	var isActive: Bool = false
	
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
	// the unambiguous "this one is going" marker. Green and pulsing rather than
	// a flat dot: a static colour reads as a badge, a heartbeat reads as *live*,
	// which is the whole point — it's what separates an app being worked on this
	// second from one merely sitting on the drawer.
	private var _activityDot: some View {
		Circle()
			.fill(Color.green)
			.overlay(
				Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1)
			)
			.frame(width: 13, height: 13)
			// A soft green glow underneath the dot so it reads as lit rather
			// than painted on, without needing a second animating ring on top
			// of a grid of already-animating icons.
			.shadow(color: Color.green.opacity(isActive ? 0.9 : 0), radius: 4)
			.shadow(color: Color.black.opacity(0.4), radius: 2, y: 1)
			// The heartbeat itself. Only runs while active; the scale and
			// opacity breathe together so it reads clearly even at 13pt.
			.scaleEffect(isActive ? (_dotPulsing ? 1.18 : 0.92) : 0.5)
			.opacity(isActive ? (_dotPulsing ? 1.0 : 0.65) : 0)
			.animation(
				isActive
					? .easeInOut(duration: 0.75).repeatForever(autoreverses: true)
					: .easeInOut(duration: 0.2),
				value: _dotPulsing
			)
			.animation(.easeInOut(duration: 0.2), value: isActive)
			.onAppear { _dotPulsing = true }
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

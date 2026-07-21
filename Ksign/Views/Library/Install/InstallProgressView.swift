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
	// the unambiguous "this one is going" marker.
	private var _activityDot: some View {
		Circle()
			.fill(Color.yellow)
			.overlay(
				Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1)
			)
			.frame(width: 13, height: 13)
			.shadow(color: Color.black.opacity(0.4), radius: 2, y: 1)
			.opacity(isActive ? 1 : 0)
			.scaleEffect(isActive ? 1 : 0.5)
			.animation(.easeInOut(duration: 0.2), value: isActive)
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

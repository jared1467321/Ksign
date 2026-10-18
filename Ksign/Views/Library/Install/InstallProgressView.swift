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
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	
	var app: AppInfoPresentable
	@ObservedObject var viewModel: InstallerStatusViewModel

	// How far along the pipeline this app is, for the dot only. Three states
	// rather than the old on/off flag, because "being worked on" covers two
	// visibly different things: the manifest that's installing right now, and
	// the apps building behind it for the manifest after that.
	enum Activity: Equatable {
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
	var animatesIcon = true

	private var _shouldPulse: Bool { animatesIcon && !reduceMotion }
	
	var body: some View {
		VStack(spacing: 12) {
			_appIcon()
				.scaleEffect(_isPulsing ? 0.85 : 0.81)
				.animation(
					_shouldPulse ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default,
					value: _isPulsing
				)
				.onAppear { _isPulsing = _shouldPulse }
				.onChange(of: _shouldPulse) { _isPulsing = $0 }
				.onDisappear { _isPulsing = false }
				// Outside the scale effect on purpose: the dot holds still
				// while the icon breathes, and it's outside the pie mask so
				// it can't be clipped by the progress fill.
				.nbThemeOverlay(alignment: .topTrailing) {
					InstallActivityDot(activity: activity, isPulsing: _isPulsing, shouldPulse: _shouldPulse)
						.equatable()
				}
		}
	}
	
	@ViewBuilder
	private func _appIcon() -> some View {
		ZStack {
			InstallStaticAppIcon(app: app)
				.equatable()
				.nbThemeOpacity(0.2)
				.frame(width: 54, height: 54)

			
			InstallStaticAppIcon(app: app)
				.equatable()
				.frame(width: 54, height: 54)
				.mask(
					ZStack {
						Circle().strokeBorder(.white, lineWidth: 4.5)
						PieShape(progress: viewModel.overallProgress)
							// Finish between 0.2s samples; animate only the path.
							.animation(.linear(duration: 0.15), value: viewModel.overallProgress)
							.scaleEffect(viewModel.isCompleted ? 2.2 : 1)
							.animation(.smooth, value: viewModel.isCompleted)
					}
				)
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

// Progress changes neither the artwork nor its border. Keep the cached image,
// loading task and theme-inspector subtree out of numeric-progress diffs.
struct InstallStaticAppIcon: View, Equatable {
	let app: AppInfoPresentable
	private let identity: String

	init(app: AppInfoPresentable) {
		self.app = app
		identity = "\(app.uuid ?? "?")|\(app.icon ?? "?")|\(app.isSigned)"
	}

	static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
	var body: some View { FRAppIconView(app: app) }
}

// Numeric progress does not change the activity marker. Keep it out of those
// diffs while preserving the glow and pulse for apps currently installing.
private struct InstallActivityDot: View, Equatable {
	let activity: InstallProgressView.Activity
	let isPulsing: Bool
	let shouldPulse: Bool

	@ViewBuilder
	var body: some View {
		if activity != .none {
			let dot: NBThemeRole = activity == .upcoming ? .tertiaryAccent : .warning
			ZStack {
				if shouldPulse {
					Circle()
						.nbThemeFill(dot)
						.frame(width: 13, height: 13)
						.blur(radius: 3.5)
						.scaleEffect(isPulsing ? 2.0 : 1.2)
						.nbThemeOpacity(isPulsing ? 0.85 : 0.3)
						.nbThemePaintLayer(0)
						.animation(
							shouldPulse ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
							value: isPulsing
						)
				}

				Circle()
					.nbThemeFill(dot)
					.nbThemeOverlay(
						Circle().nbThemeStrokeBorder(.overlayText, opacity: 0.9, lineWidth: 1)
					)
					.frame(width: 13, height: 13)
					.nbThemeShadow(dot, opacity: 0.9, radius: 4)
					.nbThemePaintLayer(1)
			}
			.nbThemePaintGroup()
			// Crossfade the purple -> orange handover.
			.animation(.easeInOut(duration: 0.2), value: activity)
			// Keep the dot on the edge of the scaled icon artwork.
			.offset(x: -5, y: 5)
		}
	}
}

//
//  TunnelHeaderView.swift
//  Feather
//
//  Created by samara on 29.04.2025.
//

import SwiftUI
import NimbleExtensions

struct TunnelHeaderView: View {
	@State var lastHeartbeatTime = Date()
	
	var body: some View {
		HStack {
			Text(.localized("Status"))
			Spacer()
			TunnelPulseRing(lastHeartbeat: $lastHeartbeatTime)
		}
		.onReceive(NotificationCenter.default.publisher(for: .heartbeat)) { _ in
			lastHeartbeatTime = Date()
		}
	}
}

struct TunnelPulseRing: View {
    @ObservedObject private var themes = NBThemeManager.shared
	@State private var _animationProgress = 0.0
	
	private let _animationDuration = 10.0
	private let _colorStartThreshold = 0.5
	private let _colorTransitionDuration = 9.0
	
	@Binding var lastHeartbeat: Date
	
	var body: some View {
		TimelineView(.animation) { timeline in
			let timeSinceHeartbeat = timeline.date.timeIntervalSince(lastHeartbeat)
			let progress = min(1.0, max(0.0, timeSinceHeartbeat / _animationDuration))
			
			let colorTransitionProgress = min(1.0,
				max(0.0, (timeSinceHeartbeat - _colorStartThreshold) / _colorTransitionDuration)
			)
			
			let pulseColor = themes.activeColor(for: .success).interpolated(
				to: themes.activeColor(for: .warning),
				fraction: colorTransitionProgress
			).color

			Circle()
				.fill(pulseColor)
                .nbThemeInspectorTarget(.success)
                .nbThemeInspectorTarget(.warning)
				.frame(width: 10, height: 10)
				.scaleEffect(1.0 - (0.5 * progress))
				.nbThemeOpacity(1.0 - (0.7 * progress))
				.animation(.easeInOut(duration: 0.3), value: lastHeartbeat)
		}
	}
}

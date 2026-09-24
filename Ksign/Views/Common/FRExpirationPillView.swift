//
//  FRExpirationPillView.swift
//  Feather
//
//  Created by samara on 7.05.2025.
//

import SwiftUI
import NimbleExtensions

// MARK: - View
struct FRExpirationPillView: View {
	let title: String
	let showOverlay: Bool
	let expiration: Date.ExpirationInfo?
	
	var body: some View {
		let labelText = showOverlay ? title : (expiration?.formatted ?? title)
		let backgroundRole: NBThemeRole = showOverlay ? .controlFill : (expiration?.role ?? .controlFill)
		
		Text(labelText)
			.lineLimit(0)
			.font(.headline.bold())
			.nbThemeForeground((showOverlay || expiration == nil) ? .accent : .onAccent)
			.padding(.horizontal, 12)
			.padding(.vertical, 6)
			.nbThemeBackground(backgroundRole, opacity: !showOverlay && expiration != nil ? 0.85 : 1)
			.nbThemeClipShape(Capsule())
			.nbThemeOverlay {
				if showOverlay, let expiration {
					Text(expiration.formatted)
						.font(.system(size: 9))
						.nbThemeForeground(expiration.role, opacity: 0.85)
						.offset(y: -23)
				}
			}
	}
}


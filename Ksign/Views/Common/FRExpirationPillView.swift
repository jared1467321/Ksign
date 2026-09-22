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
		let backgroundColor = showOverlay
		? NBHalloween.controlFill
		: (expiration?.color.opacity(0.85) ?? NBHalloween.controlFill)
		
		Text(labelText)
			.lineLimit(0)
			.font(.headline.bold())
			.foregroundStyle((showOverlay || expiration == nil) ? NBHalloween.accent : NBHalloween.onAccent)
			.padding(.horizontal, 12)
			.padding(.vertical, 6)
			.background(backgroundColor)
			.clipShape(Capsule())
			.overlay {
				if showOverlay, let expiration {
					Text(expiration.formatted)
						.font(.system(size: 9))
						.foregroundStyle(expiration.color.opacity(0.85))
						.offset(y: -23)
				}
			}
	}
}


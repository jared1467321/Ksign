//
//  NBListAdaptable.swift
//  NimbleKit
//
//  Created by samara on 7.05.2025.
//

import SwiftUI
import NimbleExtensions

public struct NBListAdaptable<Content>: View where Content: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	
	private var _content: Content
	
	public init(@ViewBuilder content: () -> Content) {
		self._content = content()
	}
	
	public var body: some View {
		Group {
			if horizontalSizeClass == .compact {
				List {
					_content
						// Deliberately clear rather than `elevated`: a plain
						// list has no inset cards to separate, so tinted rows
						// would fuse into one slab of grey edge to edge. Clear
						// lets the near-black read through and leaves the
						// cells' own styling to do the separating.
						.listRowBackground(Color.clear)
				}
				.listStyle(.plain)
				// See NBList: sets both hierarchy levels so descendant
				// `.foregroundStyle(.secondary)` picks up the green-grey.
				.foregroundStyle(NBHalloween.text, NBHalloween.textSecondary)
				.listRowSeparatorTint(NBHalloween.hairline)
				.scrollContentBackground(.hidden)
			} else {
				NBGrid {
					_content
				}
			}
		}
		.background(NBHalloween.background.ignoresSafeArea())
		// iOS 26 renders toolbar buttons inside a glass container and draws
		// their labels with the *foreground* style, not the tint — which is why
		// `window.tintColor` and `UIBarButtonItem.appearance().tintColor` both
		// left "Sources", the refresh and filter icons and Edit stubbornly
		// white. This is the SwiftUI-side equivalent and the documented way to
		// restyle bar content.
		.toolbarForegroundStyle(NBHalloween.accent, for: .navigationBar)
	}
}

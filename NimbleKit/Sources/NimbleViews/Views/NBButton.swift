//
//  FRButton.swift
//  Feather
//
//  Created by samara on 16.04.2025.
//

import SwiftUI
import NimbleExtensions

public struct NBButton: View {
	private var _title: String
	private var _icon: String
	private var _style: NBToolbarMenuStyle
	private var _horizontalPadding: CGFloat
	
	public init(
		_ title: String,
		systemImage: String,
		style: NBToolbarMenuStyle = .icon,
		horizontalPadding: CGFloat = 12
	) {
		self._title = title
		self._icon = systemImage
		self._style = style
		self._horizontalPadding = horizontalPadding
	}
	
	public var body: some View {
		// Explicit, because tint does not reach here. On iOS 26 a toolbar button
		// is drawn inside a glass container and its label takes the *foreground*
		// style, defaulting to primary — which is why every one of these
		// rendered white no matter what `window.tintColor` or the
		// `UIBarButtonItem` appearance proxy were set to.
		//
		// This is the single label used by both NBToolbarButton and
		// NBToolbarMenu, so colouring it here covers every toolbar item that
		// goes through those wrappers.
		switch _style {
		case .icon:
			Image(systemName: _icon)
				.foregroundStyle(NBHalloween.accent)

		case .text:
			Text(_title)
				.foregroundStyle(NBHalloween.accent)
		}
    }
}

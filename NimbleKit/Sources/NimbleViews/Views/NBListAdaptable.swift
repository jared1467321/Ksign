//
//  NBListAdaptable.swift
//  NimbleKit
//
//  Created by samara on 7.05.2025.
//

import SwiftUI
import NimbleExtensions

public struct NBListAdaptable<Content>: View where Content: View {
	@ObservedObject private var themeManager = NBThemeManager.shared
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
						.nbThemeRow()
				}
				.listStyle(.insetGrouped)
				.nbThemeCanvas()
			} else {
				NBGrid {
					_content
				}
				.nbThemeCanvas()
			}
		}
	}
}

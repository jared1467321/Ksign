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
	private let rendersAurora: Bool
	private let adaptsContainerText: Bool
	
	public init(rendersAurora: Bool = true, adaptsContainerText: Bool = true,
                @ViewBuilder content: () -> Content) {
		self.rendersAurora = rendersAurora
		self._content = content()
		self.adaptsContainerText = adaptsContainerText
	}
	
	public var body: some View {
		Group {
			if horizontalSizeClass == .compact {
				List {
					_content
						.nbThemeRow(adaptsText: adaptsContainerText)
				}
				.listStyle(.insetGrouped)
				.nbThemeCanvas(rendersAurora: rendersAurora, adaptsText: adaptsContainerText)
				.nbThemeTextViewport()
			} else {
				NBGrid {
					_content
				}
				.nbThemeCanvas(rendersAurora: rendersAurora, adaptsText: adaptsContainerText)
				.nbThemeTextViewport()
			}
		}
	}
}

//
//  NavigationViewWrapper.swift
//  Stars
//
//  Created by samara on 7.04.2025.
//

import SwiftUI
import NimbleExtensions

public struct NBNavigationView<Content>: View where Content: View {
	private var _title: String
	private var _mode: NavigationBarItem.TitleDisplayMode
	private var _content: Content
	private let _adaptsContainerText: Bool
	
	public init(
		_ title: String,
		displayMode: NavigationBarItem.TitleDisplayMode = .automatic,
		adaptsContainerText: Bool = true,
		@ViewBuilder content: () -> Content
	) {
		self._title = title
		self._mode = displayMode
		self._content = content()
		self._adaptsContainerText = adaptsContainerText
	}
	
	public var body: some View {
		NavigationStack {
			_content
				.nbThemeCanvas(adaptsText: _adaptsContainerText)
                .nbThemeNavigationTitle(_title, displayMode: _mode)
		}
	}
}

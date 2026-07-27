//
//  NBList.swift
//  NimbleKit
//
//  Created by samara on 7.05.2025.
//

import SwiftUI
import NimbleExtensions

public struct NBList<Content>: View where Content: View {
	public enum NBListType {
		case list
		case form
	}
	
	private var _title: String
	private var _mode: NavigationBarItem.TitleDisplayMode
	private var _type: NBListType
	private var _content: Content
	
	public init(
		_ title: String,
		displayMode: NavigationBarItem.TitleDisplayMode = .inline,
		type: NBListType = .form,
		@ViewBuilder content: () -> Content
	) {
		self._title = title
		self._mode = displayMode
		self._type = type
		self._content = content()
	}
	
	public var body: some View {
		Group {
			switch _type {
			case .form:
				Form {
					_content
						.listRowBackground(NBHalloween.elevated)
				}
			case .list:
				List {
					_content
						.listRowBackground(NBHalloween.elevated)
				}
			}
		}
		// iOS dark mode is a soft charcoal, not black. Hiding the system
		// scroll background and painting our own is the only way to get the
		// near-black the theme is built around; without this every screen
		// funnelling through here stays grey.
		//
		// `.listRowBackground` above is applied to the whole content block
		// rather than per row on purpose — it propagates down to every row in
		// every Section, and any row that sets its own still wins, since the
		// innermost modifier is the one that applies.
		// Two styles, not one: `foregroundStyle(_:_:)` sets the first and second
		// levels of the hierarchy, so every descendant that asks for
		// `.foregroundStyle(.secondary)` resolves to the green-grey instead of
		// the system's neutral grey. Doing it here means the rows themselves
		// need no edits.
		//
		// It does not catch `.foregroundColor(.secondary)` — that's a fixed
		// system colour rather than a hierarchical level, so those call sites
		// still opt out and have to be converted individually.
		.foregroundStyle(NBHalloween.text, NBHalloween.textSecondary)
		.listRowSeparatorTint(NBHalloween.hairline)
		.scrollContentBackground(.hidden)
		.background(NBHalloween.background.ignoresSafeArea())
		.navigationTitle(_title)
		.navigationBarTitleDisplayMode(_mode)
	}
}

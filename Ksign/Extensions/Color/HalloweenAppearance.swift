//
//  HalloweenAppearance.swift
//  Ksign
//
//  Everything SwiftUI can't reach.
//
//  Nav bars, tab bars, search fields and segmented controls are UIKit views
//  that SwiftUI wraps but does not restyle. They keep using the system's own
//  dark-mode greys no matter what the app tint is, which is why those parts of
//  the UI stayed black-and-white while the SwiftUI parts turned green.
//
//  The appearance proxy is the only way at them, and it has to run before any
//  window exists — proxies apply at view-creation time, so anything already on
//  screen keeps the old look. Hence the call from didFinishLaunching.
//

import UIKit
import NimbleExtensions

enum HalloweenAppearance {
	static func apply() {
		_navigationBars()
		_tabBars()
		_searchFields()
		_segmentedControls()
		_barButtons()
	}

	// MARK: - Navigation bars

	private static func _navigationBars() {
		let appearance = UINavigationBarAppearance()

		// Opaque rather than the default blur. The blur samples the content
		// behind it and lightens toward grey, which is the haze sitting behind
		// the search field.
		appearance.configureWithOpaqueBackground()
		appearance.backgroundColor = NBHalloween.uiBackground
		appearance.shadowColor = .clear

		appearance.largeTitleTextAttributes = [.foregroundColor: NBHalloween.uiTitle]
		appearance.titleTextAttributes = [.foregroundColor: NBHalloween.uiText]

		let bar = UINavigationBar.appearance()
		bar.standardAppearance = appearance
		bar.scrollEdgeAppearance = appearance
		bar.compactAppearance = appearance
		bar.compactScrollEdgeAppearance = appearance
		bar.tintColor = NBHalloween.uiAccent
	}

	// MARK: - Tab bars

	private static func _tabBars() {
		let appearance = UITabBarAppearance()
		appearance.configureWithOpaqueBackground()
		appearance.backgroundColor = NBHalloween.uiElevated
		appearance.shadowColor = .clear

		// Set on each layout because a tab bar picks its layout from size class
		// and item count at runtime; missing one leaves those items white.
		for layout in [
			appearance.stackedLayoutAppearance,
			appearance.inlineLayoutAppearance,
			appearance.compactInlineLayoutAppearance
		] {
			layout.normal.iconColor = NBHalloween.uiTextSecondary
			layout.normal.titleTextAttributes = [.foregroundColor: NBHalloween.uiTextSecondary]
			layout.selected.iconColor = NBHalloween.uiAccent
			layout.selected.titleTextAttributes = [.foregroundColor: NBHalloween.uiAccent]
		}

		let bar = UITabBar.appearance()
		bar.standardAppearance = appearance
		bar.scrollEdgeAppearance = appearance
		bar.tintColor = NBHalloween.uiAccent
		bar.unselectedItemTintColor = NBHalloween.uiTextSecondary
	}

	// MARK: - Search

	private static func _searchFields() {
		let field = UISearchTextField.appearance()
		field.backgroundColor = NBHalloween.uiElevated
		field.textColor = NBHalloween.uiText
		field.tintColor = NBHalloween.uiAccent

		// The magnifier and the clear button are template images tinted by the
		// field's own tint, but the placeholder is drawn from an attributed
		// string the proxy can't reach — so it's set per-instance below.
		UISearchBar.appearance().tintColor = NBHalloween.uiAccent
		UISearchBar.appearance().searchTextField.attributedPlaceholder = NSAttributedString(
			string: "",
			attributes: [.foregroundColor: NBHalloween.uiTextSecondary]
		)
	}

	// MARK: - Segmented controls

	private static func _segmentedControls() {
		let control = UISegmentedControl.appearance()

		// Purple rather than green: this sits directly under the nav bar, and a
		// green pill there reads as a second tint fighting the first.
		control.selectedSegmentTintColor = NBHalloween.uiPurple
		control.backgroundColor = NBHalloween.uiElevated

		control.setTitleTextAttributes(
			[.foregroundColor: NBHalloween.uiTextSecondary],
			for: .normal
		)
		control.setTitleTextAttributes(
			[.foregroundColor: UIColor.white],
			for: .selected
		)
	}

	// MARK: - Bar buttons

	private static func _barButtons() {
		let item = UIBarButtonItem.appearance()
		item.tintColor = NBHalloween.uiAccent
		item.setTitleTextAttributes([.foregroundColor: NBHalloween.uiAccent], for: .normal)
		item.setTitleTextAttributes([.foregroundColor: NBHalloween.uiAccent], for: .highlighted)
	}
}

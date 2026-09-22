//
//  HalloweenAppearance.swift
//  Ksign
//
//  UIKit appearance bridge for the currently selected Ksign theme.
//

import UIKit
import NimbleExtensions

enum HalloweenAppearance {
    static func apply(refreshExistingViews: Bool = false) {
        _navigationBars()
        _tabBars()
        _searchFields()
        _segmentedControls()
        _barButtons()

        if refreshExistingViews {
            _refreshExistingViews()
        }
    }

    // MARK: - Navigation bars

    private static func _navigationAppearance() -> UINavigationBarAppearance {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = NBHalloween.uiColor(.navigationBackground)
        appearance.shadowColor = NBHalloween.uiColor(.navigationShadow)
        appearance.largeTitleTextAttributes = [
            .foregroundColor: NBHalloween.uiColor(.navigationTitle)
        ]
        appearance.titleTextAttributes = [
            .foregroundColor: NBHalloween.uiColor(.navigationText)
        ]
        return appearance
    }

    private static func _navigationBars() {
        let appearance = _navigationAppearance()
        let bar = UINavigationBar.appearance()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactAppearance = appearance
        bar.compactScrollEdgeAppearance = appearance
        bar.tintColor = NBHalloween.uiColor(.navigationTint)
    }

    // MARK: - Tab bars

    private static func _tabAppearance() -> UITabBarAppearance {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = NBHalloween.uiColor(.tabBackground)
        appearance.shadowColor = NBHalloween.uiColor(.tabShadow)

        for layout in [
            appearance.stackedLayoutAppearance,
            appearance.inlineLayoutAppearance,
            appearance.compactInlineLayoutAppearance
        ] {
            layout.normal.iconColor = NBHalloween.uiColor(.tabUnselected)
            layout.normal.titleTextAttributes = [
                .foregroundColor: NBHalloween.uiColor(.tabUnselected)
            ]
            layout.selected.iconColor = NBHalloween.uiColor(.tabSelected)
            layout.selected.titleTextAttributes = [
                .foregroundColor: NBHalloween.uiColor(.tabSelected)
            ]
        }

        return appearance
    }

    private static func _tabBars() {
        let appearance = _tabAppearance()
        let bar = UITabBar.appearance()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.tintColor = NBHalloween.uiColor(.tabSelected)
        bar.unselectedItemTintColor = NBHalloween.uiColor(.tabUnselected)

        let item = UITabBarItem.appearance()
        item.setTitleTextAttributes(
            [.foregroundColor: NBHalloween.uiColor(.tabUnselected)],
            for: .normal
        )
        item.setTitleTextAttributes(
            [.foregroundColor: NBHalloween.uiColor(.tabSelected)],
            for: .selected
        )
    }

    // MARK: - Search

    private static func _searchFields() {
        let field = UISearchTextField.appearance()
        field.backgroundColor = NBHalloween.uiColor(.searchBackground)
        field.textColor = NBHalloween.uiColor(.searchText)
        field.tintColor = NBHalloween.uiColor(.searchTint)

        let searchBar = UISearchBar.appearance()
        searchBar.tintColor = NBHalloween.uiColor(.searchTint)
        searchBar.searchTextField.attributedPlaceholder = NSAttributedString(
            string: "",
            attributes: [.foregroundColor: NBHalloween.uiColor(.searchPlaceholder)]
        )
    }

    // MARK: - Segmented controls

    private static func _configure(_ control: UISegmentedControl) {
        control.selectedSegmentTintColor = NBHalloween.uiColor(.segmentSelectedBackground)
        control.backgroundColor = NBHalloween.uiColor(.segmentBackground)
        control.setTitleTextAttributes(
            [.foregroundColor: NBHalloween.uiColor(.segmentText)],
            for: .normal
        )
        control.setTitleTextAttributes(
            [.foregroundColor: NBHalloween.uiColor(.segmentSelectedText)],
            for: .selected
        )
    }

    private static func _segmentedControls() {
        _configure(UISegmentedControl.appearance())
    }

    // MARK: - Bar buttons

    private static func _barButtons() {
        let item = UIBarButtonItem.appearance()
        let tint = NBHalloween.uiColor(.barButtonTint)
        item.tintColor = tint
        item.setTitleTextAttributes([.foregroundColor: tint], for: .normal)
        item.setTitleTextAttributes([.foregroundColor: tint], for: .highlighted)
    }

    // MARK: - Existing UIKit wrappers

    /// Appearance proxies only affect UIKit views created after the proxy is
    /// changed. A person editing a theme should see those changes immediately,
    /// so update the wrappers that already exist in the current windows too.
    private static func _refreshExistingViews() {
        let navigation = _navigationAppearance()
        let tabs = _tabAppearance()

        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.tintColor = NBHalloween.uiColor(.accent)
                _refresh(
                    view: window,
                    navigationAppearance: navigation,
                    tabAppearance: tabs
                )
            }
        }
    }

    private static func _refresh(
        view: UIView,
        navigationAppearance: UINavigationBarAppearance,
        tabAppearance: UITabBarAppearance
    ) {
        switch view {
        case let bar as UINavigationBar:
            bar.standardAppearance = navigationAppearance
            bar.scrollEdgeAppearance = navigationAppearance
            bar.compactAppearance = navigationAppearance
            bar.compactScrollEdgeAppearance = navigationAppearance
            bar.tintColor = NBHalloween.uiColor(.navigationTint)

        case let bar as UITabBar:
            bar.standardAppearance = tabAppearance
            bar.scrollEdgeAppearance = tabAppearance
            bar.tintColor = NBHalloween.uiColor(.tabSelected)
            bar.unselectedItemTintColor = NBHalloween.uiColor(.tabUnselected)

        case let field as UISearchTextField:
            field.backgroundColor = NBHalloween.uiColor(.searchBackground)
            field.textColor = NBHalloween.uiColor(.searchText)
            field.tintColor = NBHalloween.uiColor(.searchTint)
            field.attributedPlaceholder = NSAttributedString(
                string: field.placeholder ?? "",
                attributes: [.foregroundColor: NBHalloween.uiColor(.searchPlaceholder)]
            )

        case let searchBar as UISearchBar:
            searchBar.tintColor = NBHalloween.uiColor(.searchTint)

        case let control as UISegmentedControl:
            _configure(control)

        default:
            break
        }

        for child in view.subviews {
            _refresh(
                view: child,
                navigationAppearance: navigationAppearance,
                tabAppearance: tabAppearance
            )
        }
    }
}

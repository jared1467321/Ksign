//
//  AccentColorManager.swift
//  Ksign
//
//  Compatibility wrapper for code that still asks for the app's accent color.
//  Theme profiles are the source of truth now.
//

import Combine
import SwiftUI
import UIKit
import NimbleExtensions

final class AccentColorManager: ObservableObject {
    static let shared = AccentColorManager()

    private var themeObserver: AnyCancellable?

    private init() {
        themeObserver = NBThemeManager.shared.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var currentAccentColor: Color {
        NBHalloween.accent
    }

    var currentUIColor: UIColor {
        NBHalloween.uiAccent
    }

    func updateGlobalTintColor() {
        DispatchQueue.main.async {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .forEach { window in
                    window.tintColor = NBHalloween.uiColor(.accent)
                }
        }
    }
}

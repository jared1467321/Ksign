//
//  AccentColorManager.swift
//  Ksign
//
//  Created by Nagata Asami on 6/30/25.
//

import SwiftUI
import UIKit
import NimbleExtensions

// MARK: - Accent Color Manager
class AccentColorManager: ObservableObject {
    static let shared = AccentColorManager()
    
    /// Bumped whenever entries are inserted into `_accentColors` above an
    /// existing one. `@AppStorage` stores the *index*, not the colour, so
    /// inserting at the top silently repaints everyone's app unless the saved
    /// value is shifted to match. See `_migrateStoredIndexIfNeeded()`.
    private static let _paletteVersion = 1
    private static let _paletteVersionKey = "Ksign.accentColorPaletteVersion"
    
    @AppStorage("Feather.accentColor") private var _selectedAccentColor: Int = 0 {
        didSet {
            objectWillChange.send()
        }
    }
    
    private init() {
        Self._migrateStoredIndexIfNeeded()
    }
    
    private let _accentColors: [(color: Color, uiColor: UIColor)] = [
        // Halloween — the new default. Index 0 is what every fresh install and
        // every unset preference resolves to.
        (NBHalloween.accent,  NBHalloween.uiAccent),   // 0 — Neon Green
        (NBHalloween.pumpkin, NBHalloween.uiPumpkin),  // 1 — Pumpkin
        (NBHalloween.blood,   NBHalloween.uiBlood),    // 2 — Blood
        // Upstream palette, shifted down by two.
        (Color(red: 0x53/255, green: 0x94/255, blue: 0xF7/255), UIColor(red: 0x53/255, green: 0x94/255, blue: 0xF7/255, alpha: 1.0)), // 3 — Ksign Blue
        (Color(red: 0xFF/255, green: 0x8B/255, blue: 0x92/255), UIColor(red: 0xFF/255, green: 0x8B/255, blue: 0x92/255, alpha: 1.0)), // 4 — Cherry
        (.red, .systemRed),
        (.orange, .systemOrange),
        (.yellow, .systemYellow),
        (.green, .systemGreen),
        (.blue, .systemBlue),
        (.purple, .systemPurple),
        (.pink, .systemPink),
        (.indigo, .systemIndigo),
        (.mint, .systemMint),
        (.cyan, .systemCyan),
        (.teal, .systemTeal)
    ]
    
    var currentAccentColor: Color {
        guard _selectedAccentColor < _accentColors.count else {
            return _accentColors[0].color
        }
        return _accentColors[_selectedAccentColor].color
    }
    
    var currentUIColor: UIColor {
        guard _selectedAccentColor < _accentColors.count else {
            return _accentColors[0].uiColor
        }
        return _accentColors[_selectedAccentColor].uiColor
    }
    
    /// Updates the global app tint color
    func updateGlobalTintColor() {
        DispatchQueue.main.async {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .forEach { window in
                    window.tintColor = self.currentUIColor
                }
        }
    }
    
    // MARK: - Migration
    
    /// Shifts a previously saved index so it still points at the colour the
    /// user actually picked, then records that it has done so.
    ///
    /// Someone who had chosen Cherry (old index 1) keeps Cherry (new index 4).
    /// Someone who never touched the picker (index 0, the old blue default)
    /// is left at 0 on purpose — they get the Halloween green, which is the
    /// whole point of the change.
    private static func _migrateStoredIndexIfNeeded() {
        let defaults = UserDefaults.standard
        
        guard defaults.integer(forKey: _paletteVersionKey) < _paletteVersion else { return }
        
        // A stored index only exists if the picker was actually used; an unset
        // key reads as 0, which is already where we want it.
        if defaults.object(forKey: "Feather.accentColor") != nil {
            let old = defaults.integer(forKey: "Feather.accentColor")
            if old > 0 {
                defaults.set(old + 2, forKey: "Feather.accentColor")
            }
        }
        
        defaults.set(_paletteVersion, forKey: _paletteVersionKey)
    }
}

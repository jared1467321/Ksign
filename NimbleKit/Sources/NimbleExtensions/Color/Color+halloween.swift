//
//  Color+halloween.swift
//  NimbleKit
//
//  The single source of truth for the Halloween theme.
//
//  Lives in NimbleExtensions rather than NimbleViews so that both the
//  NimbleViews list wrappers and the Ksign app target can reach it without
//  either one importing the other. Adding a file here needs no .xcodeproj
//  change — SPM picks up anything under Sources automatically.
//
//  The rule this palette follows: green is for chrome — the tint, borders,
//  highlights, the install dot. Body text stays near-white. Green-on-black
//  reads well at 40pt and badly at 13pt, so `text` is deliberately only
//  faintly green-cast rather than actually green.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

public enum NBHalloween {
	// MARK: - Surfaces

	/// Page background. Black with a faint green cast — not iOS's soft
	/// charcoal, which is what makes stock dark mode look grey next to this.
	public static let background = Color(red: 0x07/255, green: 0x0B/255, blue: 0x08/255)

	/// Rows, cards, anything sitting one layer above the background.
	public static let elevated = Color(red: 0x10/255, green: 0x17/255, blue: 0x10/255)

	/// A step above `elevated` for nested/selected surfaces.
	public static let elevatedHigh = Color(red: 0x17/255, green: 0x21/255, blue: 0x17/255)

	// MARK: - Accents

	/// Neon green. The app tint.
	public static let accent = Color(red: 0x4C/255, green: 0xE6/255, blue: 0x4C/255)

	/// Pumpkin orange. Warnings, in-progress states.
	public static let pumpkin = Color(red: 0xFF/255, green: 0x7A/255, blue: 0x18/255)

	/// Blood red. Failures, expiry, destructive actions.
	public static let blood = Color(red: 0xE0/255, green: 0x1B/255, blue: 0x1B/255)

	// MARK: - Text

	public static let text = Color(red: 0xE6/255, green: 0xF0/255, blue: 0xE6/255)
	public static let textSecondary = Color(red: 0x7E/255, green: 0x92/255, blue: 0x7F/255)

	/// Separators and card borders. Green at low alpha reads as a hairline
	/// rather than a line of colour.
	public static let hairline = accent.opacity(0.18)

	#if canImport(UIKit)
	// MARK: - UIKit twins
	//
	// Needed because window.tintColor, UINavigationBar appearance and friends
	// take UIColor, and there is no lossless Color -> UIColor conversion on
	// iOS 16 (Color(uiColor:) goes the other way; UIColor(Color) only landed
	// as reliable in 17).

	public static let uiBackground = UIColor(red: 0x07/255, green: 0x0B/255, blue: 0x08/255, alpha: 1.0)
	public static let uiElevated = UIColor(red: 0x10/255, green: 0x17/255, blue: 0x10/255, alpha: 1.0)
	public static let uiAccent = UIColor(red: 0x4C/255, green: 0xE6/255, blue: 0x4C/255, alpha: 1.0)
	public static let uiPumpkin = UIColor(red: 0xFF/255, green: 0x7A/255, blue: 0x18/255, alpha: 1.0)
	public static let uiBlood = UIColor(red: 0xE0/255, green: 0x1B/255, blue: 0x1B/255, alpha: 1.0)
	#endif
}

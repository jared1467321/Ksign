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

	/// Neon purple. The third colour, and the one that does the work orange and
	/// green can't: it fills the slots that were reading as plain grey or white
	/// chrome — large titles, the selected segment — without competing with the
	/// green tint or overloading the orange.
	public static let neonPurple = Color(red: 0xB1/255, green: 0x4C/255, blue: 0xFF/255)

	// MARK: - Chrome roles
	//
	// Named by what they're for rather than what colour they are, so a repaint
	// is one edit here instead of a hunt through appearance code.

	/// Large navigation titles.
	public static let title = neonPurple

	/// Selected segment, and other "this one is picked" surfaces that aren't
	/// the accent.
	public static let selection = neonPurple

	// MARK: - Text

	// Was 0xE6F0E6 — technically green-cast, but at 90% luminance the cast is
	// invisible and it read as plain white everywhere: settings rows, app names,
	// list titles. Pulled down to an actual light green. Still ~13:1 against the
	// background, so body copy at 13pt is unaffected legibility-wise.
	public static let text = Color(red: 0xA8/255, green: 0xE6/255, blue: 0xA8/255)
	public static let textSecondary = Color(red: 0x7E/255, green: 0x92/255, blue: 0x7F/255)

	/// Separators and card borders. Green at low alpha reads as a hairline
	/// rather than a line of colour.
	public static let hairline = accent.opacity(0.18)

	// MARK: - Chrome
	//
	// Orange doing a job that isn't "something is wrong". The status ladder
	// below is honest but rare — a user only meets `warning` and `danger` when
	// a cert is expiring or an install fails — so a theme built purely on it
	// reads as all-green in normal use, which is exactly what happened.
	//
	// These are the decorative slots: places orange appears because the theme
	// says so, not because anything is happening. Kept separate from `warning`
	// so the two meanings can diverge later without a find-and-replace.

	/// Section headers. The single highest-traffic piece of chrome in the app —
	/// every list on every screen has at least one.
	public static let heading = pumpkin

	/// Backing for small count/badge pills sitting next to a heading.
	public static let headingFill = pumpkin.opacity(0.16)

	// MARK: - Status
	//
	// The app has one three-state ladder running through it — something is
	// finished, working, or broken — and the palette has exactly three
	// colours. Binding them here rather than reaching for `.green` / `.orange`
	// / `.red` at each call site is what makes orange and red *structural*
	// instead of decorative: they show up because a cert is expiring or an
	// install failed, not because someone chose them from a picker.
	//
	// Yellow is deliberately absent. It was in the upstream expiration ladder
	// as a fourth step, but it isn't in this palette, and a four-colour ladder
	// squeezed into three colours reads better as three.

	/// Valid, installed, complete, healthy.
	public static let ok = accent

	/// In progress, queued, expiring soon, needs attention but not broken.
	public static let warning = pumpkin

	/// Failed, revoked, expired, destructive.
	public static let danger = blood

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
	public static let uiPurple = UIColor(red: 0xB1/255, green: 0x4C/255, blue: 0xFF/255, alpha: 1.0)
	public static let uiElevatedHigh = UIColor(red: 0x17/255, green: 0x21/255, blue: 0x17/255, alpha: 1.0)
	public static let uiText = UIColor(red: 0xA8/255, green: 0xE6/255, blue: 0xA8/255, alpha: 1.0)
	public static let uiTextSecondary = UIColor(red: 0x7E/255, green: 0x92/255, blue: 0x7F/255, alpha: 1.0)

	/// UIKit twin of `title`.
	public static let uiTitle = uiPurple
	#endif
}

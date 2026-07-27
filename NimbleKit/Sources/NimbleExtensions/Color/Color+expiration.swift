//
//  UIColor+expiration.swift
//  Feather
//
//  Created by samara on 16.04.2025.
//

import SwiftUI

extension Color {
	/// The expiry ladder, on the Halloween palette.
	///
	/// This is the highest-traffic colour in the app — it backs the Install
	/// pill on every library cell and every certificate row — so it's the one
	/// place where getting orange and red in front of you matters most.
	///
	/// The upstream ladder had four steps (red / orange / yellow / green).
	/// Yellow isn't in this palette, so the 30–60 day band folds into pumpkin
	/// alongside 14–30. That's not a loss of information: both bands mean the
	/// same thing to you — renew this soon-ish — and the two that carry real
	/// urgency, "about to die" and "fine", stay distinct at the ends.
	static public func expiration(days: Int) -> Color {
		switch days {
		case ..<14:
			return NBHalloween.danger   // Blood — days left, act now
		case 14..<60:
			return NBHalloween.warning  // Pumpkin — renew soon
		default:
			return NBHalloween.ok       // Neon green — healthy
		}
	}
}

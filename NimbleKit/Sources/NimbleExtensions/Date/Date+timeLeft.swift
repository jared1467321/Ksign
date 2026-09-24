//
//  Date+timeLeft.swift
//  Feather
//
//  Created by samara on 16.04.2025.
//

import Foundation
import SwiftUI

extension Date {
	public struct ExpirationInfo {
		public let formatted: String
		public var color: Color { NBHalloween.themeColor(role).color }
		public let role: NBThemeRole
		public let icon: String
	}
	
	/// Gathers data for `ExpirationInfo`
	/// - Parameter now: Date
	/// - Returns: `ExpirationInfo`
	public func expirationInfo(from now: Date = .now) -> ExpirationInfo {
		let timeLeft = self.timeIntervalSince(now)
		
		guard timeLeft > 0 else {
			return ExpirationInfo(
				formatted: .localized("Expired"),
				role: .expired,
				icon: "xmark.octagon"
			)
		}
		
		let daysLeft = Int(timeLeft / 86400)
		let role: NBThemeRole = daysLeft < 14 ? .danger : daysLeft < 60 ? .warning : .success
		
		let formatter = Date._expirationFormatter(for: timeLeft)
		let timeString = formatter.string(from: timeLeft) ?? .localized("%lld days", arguments: daysLeft)
		
		return ExpirationInfo(
			formatted: timeString,
			role: role,
			icon: "clock"
		)
	}
	
	private static func _expirationFormatter(for interval: TimeInterval) -> DateComponentsFormatter {
		let formatter = DateComponentsFormatter()
		formatter.allowedUnits = interval < 3600
		? [.minute]
		: interval < 86400
		? [.hour]
		: [.day]
		formatter.unitsStyle = .full
		return formatter
	}
}

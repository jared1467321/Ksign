//
//  ZipCompression+cases.swift
//  Feather
//
//  Archive compression/settings compatibility for minizip-ng.
//

import Foundation
import ASignArchiveKit

extension ASignArchiveCompression {
	var label: String {
		switch self {
		case .none: return "None"
		case .speed: return "Speed"
		case .standard: return "Default"
		case .best: return "Best"
		}
	}
}

enum ArchiveExtractionLibrary {
	static let miniZip = "minizip-ng"
	static let zipFoundation = "ZIPFoundation"
	static let legacyZip = "Zip"

	static func normalized(_ value: String?) -> String {
		value == zipFoundation ? zipFoundation : miniZip
	}

	static func migrateStoredPreference() {
		let defaults = UserDefaults.standard
		guard defaults.string(forKey: "Feather.extractionLibrary") == legacyZip else { return }
		defaults.set(miniZip, forKey: "Feather.extractionLibrary")
	}
}

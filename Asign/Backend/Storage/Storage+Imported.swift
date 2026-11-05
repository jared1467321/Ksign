//
//  Storage+Imported.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//

import CoreData
import UIKit.UIImpactFeedbackGenerator

// MARK: - Class extension: Imported Apps
extension Storage {
	func addImported(
		uuid: String,
		source: URL? = nil,
		
		appName: String? = nil,
		appIdentifier: String? = nil,
		appVersion: String? = nil,
		appIcon: String? = nil,
		
		completion: @escaping (Error?) -> Void
	) {
		insertLibraryRecord({ worker in
            let new = Imported(context: worker)
            new.uuid = uuid
            new.source = source
            new.date = Date()
            new.identifier = appIdentifier
            new.name = appName
            new.icon = appIcon
            new.version = appVersion
            return new
        }, completion: completion)
	}
}

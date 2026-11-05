//
//  Storage+Signed.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import CoreData
import UIKit.UIImpactFeedbackGenerator

// MARK: - Class extension: Signed Apps
extension Storage {
	func addSigned(
		uuid: String,
		source: URL? = nil,
		certificate: CertificatePair? = nil,
		
		appName: String? = nil,
		appIdentifier: String? = nil,
		appVersion: String? = nil,
		appIcon: String? = nil,
		
		completion: @escaping (Error?) -> Void
	) {
		// Read the relationship on its owning queue; only its permanent ID is
        // passed to the writer, never the UI's managed object.
        context.perform {
            let certificateID = certificate?.objectID
            self.insertLibraryRecord({ worker in
                let new = Signed(context: worker)
                new.uuid = uuid
                new.source = source
                new.date = Date()
                if let certificateID {
                    new.certificate = try worker.existingObject(with: certificateID) as? CertificatePair
                }
                new.identifier = appIdentifier
                new.name = appName
                new.icon = appIcon
                new.version = appVersion
                return new
            }, completion: completion)
        }
	}
}

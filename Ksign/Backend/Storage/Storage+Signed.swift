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
		// Same fix as `addImported` — see the note there. `FR.signPackageFile`
		// runs `SigningHandler` in a detached task, so this had the identical
		// off-queue insert into the main-queue `viewContext`.
		context.perform {
			let new = Signed(context: self.context)
			
			new.uuid = uuid
			new.source = source
			new.date = Date()
			// if nil, we assume adhoc or certificate was deleted afterwards
			new.certificate = certificate
			// could possibly be nil, but thats fine.
			new.identifier = appIdentifier
			new.name = appName
			new.icon = appIcon
			new.version = appVersion
			
			self.saveContext()
			UIImpactFeedbackGenerator(style: .light).impactOccurred()
			completion(nil)
		}
	}
}

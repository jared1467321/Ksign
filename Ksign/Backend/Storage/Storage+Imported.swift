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
		// `context` is the container's `viewContext`, which is bound to the
		// main queue. This body used to run wherever it was called from —
		// and the import path calls it from `AppFileHandler.addToDatabase()`,
		// which lives inside `FR.handlePackageFile`'s detached task. So a
		// background thread was inserting into a main-queue context while
		// `LibraryView`'s @FetchRequests were reading from that same context
		// on the main thread.
		//
		// Core Data doesn't fail loudly on that. It takes its internal locks
		// out of order, and when the timing lines up the app simply stops —
		// no crash, no log, nothing written badly, which is why a relaunch
		// and a retry of the exact same files works fine. Bulk import runs
		// two at a time, so it had two background threads racing the main
		// one, which is where it actually showed up.
		//
		// `perform` hops onto the context's own queue before touching
		// anything. It also puts the haptic — a UIKit object that was being
		// constructed and fired off the main thread — back where it belongs.
		context.perform {
			let new = Imported(context: self.context)
			
			new.uuid = uuid
			new.source = source
			new.date = Date()
			// could possibly be nil, but thats fine.
			// ?
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

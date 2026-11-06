//
//  Storage+Sources.swift
//  Feather
//
//  Created by samara on 12.04.2025.
//

import CoreData
import AltSourceKit

// MARK: - Class extension: Sources
extension Storage {
	/// Retrieve sources in an array, we don't normally need this in swiftUI but we have it for the copy sources action
	func getSources() -> [AltSource] {
		let request: NSFetchRequest<AltSource> = AltSource.fetchRequest()
		return (try? context.fetch(request)) ?? []
	}
	
	private struct SourceRecord {
		let url: URL
		let name: String?
		let identifier: String
		let iconURL: URL?
		let isBuiltIn: Bool
	}

	func addSource(_ url: URL, name: String? = "Unknown", identifier: String,
				   iconURL: URL? = nil, isBuiltIn: Bool = false,
				   completion: @escaping (Error?) -> Void) {
		writeSources([SourceRecord(url: url, name: name, identifier: identifier,
								   iconURL: iconURL, isBuiltIn: isBuiltIn)], completion: completion)
	}

	func addSource(_ url: URL, repository: ASRepository, id: String = "", isBuiltIn: Bool = false,
				   completion: @escaping (Error?) -> Void) {
		addSource(url, name: repository.name,
				  identifier: id.isEmpty ? (repository.id ?? url.absoluteString) : id,
				  iconURL: repository.currentIconURL, isBuiltIn: isBuiltIn, completion: completion)
	}

	func addSources(repos: [URL: ASRepository], completion: @escaping (Error?) -> Void) {
		let records = repos.map { url, repository in
			SourceRecord(url: url, name: repository.name, identifier: repository.id ?? url.absoluteString,
						 iconURL: repository.currentIconURL, isBuiltIn: false)
		}
		writeSources(records, completion: completion)
	}

	private func writeSources(_ records: [SourceRecord], completion: @escaping (Error?) -> Void) {
		// One private context serializes duplicate checks with insertion, even
		// when several source downloads finish at once. Publish only saved IDs.
		let worker = sourceWriteContext
		worker.perform {
			do {
				var inserted: [NSManagedObject] = []
				for record in records {
					let request: NSFetchRequest<AltSource> = AltSource.fetchRequest()
					request.predicate = NSPredicate(format: "identifier == %@", record.identifier)
					guard try worker.count(for: request) == 0 else { continue }
					let source = AltSource(context: worker)
					source.name = record.name
					source.date = Date()
					source.identifier = record.identifier
					source.sourceURL = record.url
					source.iconURL = record.iconURL
					source.isBuiltIn = record.isBuiltIn
					inserted.append(source)
				}
				try worker.save()
				let ids = inserted.map(\.objectID)
				worker.reset()
				self.context.perform {
					NSManagedObjectContext.mergeChanges(fromRemoteContextSave:
						[NSInsertedObjectsKey: ids], into: [self.context])
					completion(nil)
				}
			} catch {
				worker.rollback()
				worker.reset()
				self.context.perform { completion(error) }
			}
		}
	}


	func addBuiltInSources() {
		let builtInSourceURLs = [
			"https://community-apps.sidestore.io/sidecommunity.json",
			"https://github.com/LiveContainer/LiveContainer/releases/download/1.0/apps.json",
			"https://alt.crystall1ne.dev"
		]
		
		for urlString in builtInSourceURLs {
			FR.handleSource(urlString) { }
		}
	}

	func deleteSource(for source: AltSource) {
		context.delete(source)
		saveContext()
	}

	func sourceExists(_ identifier: String) async -> Bool {
		await sourceWriteContext.perform {
			let request: NSFetchRequest<AltSource> = AltSource.fetchRequest()
			request.predicate = NSPredicate(format: "identifier == %@", identifier)
			return ((try? self.sourceWriteContext.count(for: request)) ?? 0) > 0
		}
	}
}

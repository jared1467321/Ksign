//
//  Persistence.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import CoreData
import UIKit.UIImpactFeedbackGenerator

// MARK: - Class
final class Storage: ObservableObject {
	static let shared = Storage()
	let container: NSPersistentContainer
	let sourceWriteContext: NSManagedObjectContext
	private let libraryWriteContext: NSManagedObjectContext
	
	private let _name: String = "Feather"
	
	init(inMemory: Bool = false) {
		container = NSPersistentContainer(name: _name)
		
		if inMemory {
			container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
		}
		
		container.loadPersistentStores(completionHandler: { (storeDescription, error) in
			if let error = error as NSError? {
				fatalError("Unresolved error \(error), \(error.userInfo)")
			}
		})
		
		sourceWriteContext = container.newBackgroundContext()
		libraryWriteContext = container.newBackgroundContext()
		container.viewContext.automaticallyMergesChangesFromParent = true
	}
	
	var context: NSManagedObjectContext {
		container.viewContext
	}

    /// Serialize library inserts because signing with the same certificate
    /// also updates that certificate's inverse relationship.
    func insertLibraryRecord(_ create: @escaping (NSManagedObjectContext) throws -> NSManagedObject,
                             completion: @escaping (Error?) -> Void) {
        let worker = libraryWriteContext
        worker.perform {
            defer { worker.reset() }
            do {
                let record = try create(worker)
                try worker.save()
                let id = record.objectID
                self.context.perform {
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave:
                        [NSInsertedObjectsKey: [id]], into: [self.context])
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    completion(nil)
                }
            } catch {
                self.context.perform { completion(error) }
            }
        }
    }
	
	func saveContext() {
        DispatchQueue.main.async {
            if self.context.hasChanges {
                try? self.context.save()
            }
        }
	}
	
	func clearContext<T: NSManagedObject>(request: NSFetchRequest<T>) async {
		let deleteRequest = NSBatchDeleteRequest(fetchRequest: (request as? NSFetchRequest<NSFetchRequestResult>)!)
		deleteRequest.resultType = .resultTypeObjectIDs
		let worker = container.newBackgroundContext()
		do {
			let ids = try await worker.perform {
				(try worker.execute(deleteRequest) as? NSBatchDeleteResult)?.result as? [NSManagedObjectID] ?? []
			}
			await context.perform {
				NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSDeletedObjectsKey: ids], into: [self.context])
			}
		} catch { print("clear: \(error.localizedDescription)") }
	}
    
    func countContent<T: NSManagedObject>(for type: T.Type) async -> String {
        let request = T.fetchRequest()
        let worker = container.newBackgroundContext()
        return await worker.perform { "\((try? worker.count(for: request)) ?? 0)" }
    }
}

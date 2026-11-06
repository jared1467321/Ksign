//
//  SourcesViewModel.swift
//  Feather
//
//  Created by samara on 30.04.2025.
//

import Foundation
import AltSourceKit
import SwiftUI
import NimbleJSON

// MARK: - Class
@MainActor
final class SourcesViewModel: ObservableObject {
	static let shared = SourcesViewModel()
	
	typealias RepositoryDataHandler = Result<ASRepository, Error>
	
	private let _dataService = NBFetchService()
	
	var isFinished = true
	@Published var sources: [AltSource: ASRepository] = [:]
	
	func fetchSources(_ sources: FetchedResults<AltSource>, refresh: Bool = false, batchSize: Int = 4) async {
		guard isFinished else { return }
		
		// check if sources to be fetched are the same as before, if yes, return
		// also skip check if refresh is true
		if !refresh, sources.allSatisfy({ self.sources[$0] != nil }) { return }
		
		// isfinished is used to prevent multiple fetches at the same time
		isFinished = false
		defer { isFinished = true }
		
		self.sources = [:]
		
		let sourcesArray = Array(sources)
		// Managed objects stay on MainActor. Child tasks receive URLs and indices.
		let urls = sourcesArray.map(\.sourceURL)
		let dataService = _dataService
		let batchSize = max(1, batchSize)
		
		for startIndex in stride(from: 0, to: sourcesArray.count, by: batchSize) {
			let endIndex = min(startIndex + batchSize, sourcesArray.count)
			let batchResults = await withTaskGroup(of: (Int, ASRepository?).self, returning: [Int: ASRepository].self) { group in
				for index in startIndex..<endIndex {
					let url = urls[index]
					group.addTask {
						guard let url else {
							return (index, nil)
						}
						
						return await withCheckedContinuation { continuation in
							dataService.fetch(from: url) { (result: RepositoryDataHandler) in
								switch result {
								case .success(let repo):
									continuation.resume(returning: (index, repo))
								case .failure(_):
									continuation.resume(returning: (index, nil))
								}
							}
						}
					}
				}
				
				var results = [Int: ASRepository]()
				for await (index, repo) in group {
					if let repo {
						results[index] = repo
					}
				}
				return results
			}
			
			for (index, repo) in batchResults {
				let source = sourcesArray[index]
				if !source.isDeleted { self.sources[source] = repo }
			}
		}
	}
}

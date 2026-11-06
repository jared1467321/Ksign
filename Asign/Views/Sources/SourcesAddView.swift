//
//  SourcesAddView.swift
//  Feather
//
//  Created by samara on 1.05.2025.
//

import SwiftUI
import NimbleExtensions
import NimbleViews
import AltSourceKit
import NimbleJSON

// MARK: - View
struct SourcesAddView: View {
	@Environment(\.dismiss) var dismiss
	
	typealias RepositoryDataHandler = Result<ASRepository, Error>
	
	private let _dataService = NBFetchService()
	
	@State private var _isImporting = false
	@State private var _sourceURL = ""
	
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Add Source"), displayMode: .inline) {
			Form {
				Group {
				Section {
					TextField(.localized("Source Repo URL"), text: $_sourceURL)
						.keyboardType(.URL)
				} footer: {
					Text(.localized("Enter a URL to start validation."))
					.nbThemeForeground(.textSecondary)
				}
				
				Section {
					Button(.localized("Import"), systemImage: "square.and.arrow.down") {
						_isImporting = true
						_addCode(UIPasteboard.general.string) {
							UINotificationFeedbackGenerator().notificationOccurred(.success)
							dismiss()
						}
						
					}
					
					Button(.localized("Export"), systemImage: "doc.on.clipboard") {
						UIPasteboard.general.string = Storage.shared.getSources().map {
							$0.sourceURL!.absoluteString
						}.joined(separator: "\n")
						UINotificationFeedbackGenerator().notificationOccurred(.success)
						UIAlertController.showAlertWithOk(title: .localized("Success"), message: .localized("All sources copied to clipboard."))
					}
				} footer: {
					Text(.localized("Supports importing from KravaSign/MapleSign and ESign"))
					.nbThemeForeground(.textSecondary)
				}
				}
				.nbThemeRow()
			}
			.nbThemeCanvas(rendersAurora: false)
			.toolbar {
				NBToolbarButton(role: .cancel)
				
				if !_isImporting {
					NBToolbarButton(
						.localized("Save"),
						style: .text,
						placement: .confirmationAction,
						isDisabled: _sourceURL.isEmpty
					) {
						FR.handleSource(_sourceURL) {
							dismiss()
						}
					}
				} else {
					ToolbarItem(placement: .confirmationAction) {
						ProgressView()
						.nbThemeTint(.accent)
					}
				}
			}
		}
	}
	
	private func _addCode(
		_ code: String?,
		competion: @escaping () -> Void
	) {
		guard let code else { _isImporting = false; return }
		let dataService = _dataService
		Task { @MainActor in
			let urls = (try? await BackgroundFileWork.perform {
				ASDeobfuscator.decode(with: code).compactMap { URL(string: $0) }
			}) ?? []
			guard !urls.isEmpty else { _isImporting = false; return }
			var repositories: [URL: ASRepository] = [:]
			for start in stride(from: 0, to: urls.count, by: 4) {
				let batch = urls[start..<min(start + 4, urls.count)]
				let results = await withTaskGroup(of: (URL, ASRepository?).self) { group in
					for url in batch {
						group.addTask {
							await withCheckedContinuation { continuation in
								dataService.fetch(from: url) { (result: RepositoryDataHandler) in
									continuation.resume(returning: (url, try? result.get()))
								}
							}
						}
					}
					var results: [URL: ASRepository] = [:]
					for await (url, repository) in group {
						if let repository { results[url] = repository }
					}
					return results
				}
				repositories.merge(results, uniquingKeysWith: { _, latest in latest })
			}
			Storage.shared.addSources(repos: repositories) { error in
				_isImporting = false
				if let error {
					UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
				} else { competion() }
			}
		}
	}
}

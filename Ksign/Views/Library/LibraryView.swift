//
//  ContentView.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import CoreData
import NimbleViews

// A small Identifiable wrapper so the post-sign install can use an
// item-based sheet (reliable) instead of a bool-based one (races with
// the signing sheet's dismissal and gets dropped).
struct BulkInstallRequest: Identifiable {
	let id = UUID()
	let apps: [AppInfoPresentable]
}

// Carries the apps AND the sign-and-install flag as one atomic value, so
// the flag can't lag behind the presentation (a bool flag set alongside a
// separate "isPresented" bool can be read before it settles, which made
// "Sign & Install" behave like plain "Sign").
struct BulkSignRequest: Identifiable {
	let id = UUID()
	let apps: [AppInfoPresentable]
	let signAndInstall: Bool
}

// MARK: - View
struct LibraryView: View {
	@StateObject var downloadManager = DownloadManager.shared
	
	@State private var _selectedInfoAppPresenting: AnyApp?
	@State private var _selectedSigningAppPresenting: AnyApp?
	@State private var _selectedInstallAppPresenting: AnyApp?
	@State private var _selectedAppDylibsPresenting: AnyApp?
	@State private var _bulkSignRequest: BulkSignRequest?
	@State private var _isImportingPresenting = false
	@State private var _isDownloadingPresenting = false

	@State private var _alertDownloadString: String = "" // for _isDownloadingPresenting
	@State private var _searchText = ""
	@State private var _selectedTab: Int = 0 // 0 for Downloaded, 1 for Signed
	
	// MARK: Edit Mode
    @State private var _isEditMode: EditMode = .inactive
	@State private var _selectedApps: Set<String> = []
	
	@Namespace private var _namespace
	
	// horror
	private func filteredAndSortedApps<T>(from apps: FetchedResults<T>) -> [T] where T: NSManagedObject {
		apps.filter {
			_searchText.isEmpty ||
			(($0.value(forKey: "name") as? String)?.localizedCaseInsensitiveContains(_searchText) ?? false)
		}
	}
	
	private var _filteredSignedApps: [Signed] {
		filteredAndSortedApps(from: _signedApps)
	}
	
	private var _filteredImportedApps: [Imported] {
		filteredAndSortedApps(from: _importedApps)
	}
	
	// MARK: Fetch
	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
		animation: .snappy
	) private var _signedApps: FetchedResults<Signed>
	
	@FetchRequest(
		entity: Imported.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)],
		animation: .snappy
	) private var _importedApps: FetchedResults<Imported>
	
	// MARK: Body
    var body: some View {
		NBNavigationView(.localized("Library")) {
			VStack(spacing: 0) {
				Picker("", selection: $_selectedTab) {
					Text(.localized("Downloaded Apps")).tag(0)
					Text(.localized("Signed Apps")).tag(1)
				}
				.pickerStyle(SegmentedPickerStyle())
				.padding(.horizontal)
				.padding(.vertical, 8)
				
				NBListAdaptable {
					if _selectedTab == 0 {
						NBSection(
							.localized("Downloaded Apps"),
							secondary: _filteredImportedApps.count.description
						) {
							ForEach(_filteredImportedApps, id: \.uuid) { app in
								LibraryCellView(
									app: app,
									selectedInfoAppPresenting: $_selectedInfoAppPresenting,
									selectedSigningAppPresenting: $_selectedSigningAppPresenting,
									selectedInstallAppPresenting: $_selectedInstallAppPresenting,
									selectedAppDylibsPresenting: $_selectedAppDylibsPresenting,
									selectedApps: $_selectedApps
								)
								.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
							}
						}
					} else {
						NBSection(
							.localized("Signed Apps"),
							secondary: _filteredSignedApps.count.description
						) {
							ForEach(_filteredSignedApps, id: \.uuid) { app in
								LibraryCellView(
									app: app,
									selectedInfoAppPresenting: $_selectedInfoAppPresenting,
									selectedSigningAppPresenting: $_selectedSigningAppPresenting,
									selectedInstallAppPresenting: $_selectedInstallAppPresenting,
									selectedAppDylibsPresenting: $_selectedAppDylibsPresenting,
									selectedApps: $_selectedApps
								)
								.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
							}
						}
					}
				}
			}
			.searchable(text: $_searchText, placement: .platform())
            .overlay {
                if
                    _filteredSignedApps.isEmpty,
                    _filteredImportedApps.isEmpty
                {
                    if #available(iOS 17, *) {
                        ContentUnavailableView {
                            Label(.localized("No Apps"), systemImage: "questionmark.app.fill")
                        } description: {
                            Text(.localized("Get started by importing your first IPA file."))
                        } actions: {
                            Menu {
                                _importActions()
                            } label: {
                                Text("Import").bg()
                            }
                        }
                    }
                }
            }
			.toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    EditButton()
                    if _isEditMode.isEditing {
                        Button {
                            _toggleSelectAll()
                        } label: {
                            Text(_allCurrentTabSelected ? .localized("Deselect All") : .localized("Select All"))
                        }
                        .disabled(_currentTabUUIDs.isEmpty)
                    }
                }
                if _isEditMode.isEditing {
					ToolbarItemGroup(placement: .topBarTrailing) {
                        if _selectedTab == 0 {
                            Button {
                                _bulkSignRequest = BulkSignRequest(apps: _resolveSelectedApps(), signAndInstall: false)
                            } label: {
                                NBButton(.localized("Sign"), systemImage: "signature", style: .icon)
                            }
                            .disabled(_selectedApps.isEmpty)

                            Button {
                                _bulkSignRequest = BulkSignRequest(apps: _resolveSelectedApps(), signAndInstall: true)
                            } label: {
                                NBButton(.localized("Sign & Install"), systemImage: "arrow.down.app", style: .icon)
                            }
                            .disabled(_selectedApps.isEmpty)
                        } else {
                            Button {
                                InstallSession.shared.start(apps: _resolveSelectedApps())
                            } label: {
                                NBButton(.localized("Install"), systemImage: "square.and.arrow.down")
                            }
                            .disabled(_selectedApps.isEmpty)
                        }
						Button {
							_bulkDeleteSelectedApps()
						} label: {
							NBButton(.localized("Delete"), systemImage: "trash", style: .icon)
						}
						.disabled(_selectedApps.isEmpty)
					}
				} else {
					NBToolbarMenu(
						systemImage: "plus",
						style: .icon,
						placement: .topBarTrailing
					) {
                        _importActions()
                    }
				}
			}
            .environment(\.editMode, $_isEditMode)
			.sheet(item: $_selectedInfoAppPresenting) { app in
				LibraryInfoView(app: app.base)
			}
			.sheet(item: $_selectedInstallAppPresenting) { app in
				InstallPreviewView(app: app.base, isSharing: app.archive)
					.presentationDetents([.height(200)])
					.presentationDragIndicator(.visible)			}
			.fullScreenCover(item: $_selectedSigningAppPresenting) { app in
				SigningView(app: app.base, signAndInstall: app.signAndInstall)
					.compatNavigationTransition(id: app.base.uuid ?? "", ns: _namespace)
			}
			.fullScreenCover(item: $_selectedAppDylibsPresenting) { app in
                DylibsView(app: app.base)
					.compatNavigationTransition(id: app.base.uuid ?? "", ns: _namespace)
			}
			.fullScreenCover(item: $_bulkSignRequest) { request in
				BulkSigningView(apps: request.apps, signAndInstall: request.signAndInstall)
				.compatNavigationTransition(id: request.id.uuidString, ns: _namespace)
				.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ksign.bulkSigningFinished"))) { notification in
					_selectedTab = 1
				}
			}
			.sheet(isPresented: $_isImportingPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes:  [.ipa, .tipa],
					allowsMultipleSelection: true,
					onDocumentsPicked: { urls in
						guard !urls.isEmpty else { return }
						_importIPAs(Array(urls))
					}
				)
			}
			.alert(.localized("Import from URL"), isPresented: $_isDownloadingPresenting) {
				TextField(.localized("URL"), text: $_alertDownloadString)
				Button(.localized("Cancel"), role: .cancel) {
					_alertDownloadString = ""
				}
				Button(.localized("OK")) {
					if let url = URL(string: _alertDownloadString) {
						_ = downloadManager.startDownload(from: url, id: "FeatherManualDownload_\(UUID().uuidString)")
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("feather.installApp"))) { notification in
                if let app = _signedApps.first {
                    _selectedInstallAppPresenting = AnyApp(base: app)
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ksign.bulkSignAndInstall"))) { notification in
				// Bulk signing just finished with "Sign & Install". The
				// object carries how many apps were signed; they're the
				// newest entries in the (date-descending) signed list.
				guard let count = notification.object as? Int, count > 0 else { return }
				let newest = Array(_signedApps.prefix(count)).map { $0 as AppInfoPresentable }
				guard !newest.isEmpty else { return }
				// No presentation race to dodge any more: the drawer isn't a
				// sheet on this screen, so it can't be dropped by the signing
				// sheet dismissing at the same moment.
				InstallSession.shared.start(apps: newest)
			}
        }
        .onChange(of: _isEditMode) { state in
            if !state.isEditing {
                DispatchQueue.main.asyncAfter(deadline: .now()) {
                    withAnimation{
                        _selectedApps.removeAll()
                    }
                }
            }
        }
    }
}

extension LibraryView {
    // UUIDs of the apps in the currently-visible tab (respects the search
    // filter). Select All operates only on these, so it stays scoped to the
    // Downloaded tab or the Signed tab depending on where you are.
    private var _currentTabUUIDs: [String] {
        _selectedTab == 0
            ? _filteredImportedApps.compactMap { $0.uuid }
            : _filteredSignedApps.compactMap { $0.uuid }
    }

    private var _allCurrentTabSelected: Bool {
        let ids = _currentTabUUIDs
        return !ids.isEmpty && ids.allSatisfy { _selectedApps.contains($0) }
    }

    private func _toggleSelectAll() {
        let ids = _currentTabUUIDs
        withAnimation {
            if _allCurrentTabSelected {
                ids.forEach { _selectedApps.remove($0) }
            } else {
                ids.forEach { _selectedApps.insert($0) }
            }
        }
    }

    // Resolves the currently-selected UUIDs into app objects, checking both
    // the imported and signed lists.
    private func _resolveSelectedApps() -> [AppInfoPresentable] {
        _selectedApps.compactMap { id in
            (_importedApps.first(where: { $0.uuid == id }) as AppInfoPresentable?)
            ?? (_signedApps.first(where: { $0.uuid == id }) as AppInfoPresentable?)
        }
    }

    @ViewBuilder
    private func _importActions() -> some View {
        Button(.localized("Import from Files"), systemImage: "folder") {
            _isImportingPresenting = true
        }
        Button(.localized("Import from URL"), systemImage: "globe") {
            _isDownloadingPresenting = true
        }
    }

    // Imports IPAs with a bounded queue: at most `maxConcurrent` files are
    // extracted at once, the rest wait their turn. Importing 5+ at once used
    // to kick off every extraction simultaneously and freeze the app.
    private func _importIPAs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let maxConcurrent = 2

        Task {
            await withTaskGroup(of: Void.self) { group in
                var next = 0

                // Prime the queue with up to `maxConcurrent` imports.
                let initial = min(maxConcurrent, urls.count)
                while next < initial {
                    let url = urls[next]
                    next += 1
                    group.addTask { await Self._importOne(url) }
                }

                // Each time one finishes, start the next one — so the number
                // in flight never exceeds `maxConcurrent`.
                while await group.next() != nil {
                    if next < urls.count {
                        let url = urls[next]
                        next += 1
                        group.addTask { await Self._importOne(url) }
                    }
                }
            }
        }
    }

    // Extracts a single IPA and adds it to the library. Static + using the
    // shared manager so the task-group closures don't capture the view.
    private static func _importOne(_ url: URL) async {
        let manager = DownloadManager.shared
        let id = "FeatherManualDownload_\(UUID().uuidString)"
        let dl = await MainActor.run { manager.startArchive(from: url, id: id) }

        do {
            try await manager.handlePachageFile(url: url, dl: dl)
        } catch {
            await MainActor.run {
                UIAlertController.showAlertWithOk(
                    title: "Error",
                    message: .localized("Whoops!, something went wrong when extracting the file. \nMaybe try switching the extraction library in the settings?")
                )
            }
        }
    }
}


// MARK: - Extension: View (Edit Mode Functions)
extension LibraryView {
	private func _bulkDeleteSelectedApps() {
		let appsToDelete = _selectedApps
		
		withAnimation(.easeInOut(duration: 0.5)) {
			for appUUID in appsToDelete {
				if let signedApp = _signedApps.first(where: { $0.uuid == appUUID }) {
					Storage.shared.deleteApp(for: signedApp)
				} else if let importedApp = _importedApps.first(where: { $0.uuid == appUUID }) {
					Storage.shared.deleteApp(for: importedApp)
				}
			}
		}
		
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
			_selectedApps.removeAll()
		}
	}
}

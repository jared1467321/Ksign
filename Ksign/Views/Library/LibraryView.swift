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

// A re-entrancy gate for nav-bar buttons.
//
// This is now the only thing standing between a fast double tap and a second
// transition starting on top of the first. It refuses a tap arriving inside the
// settle window, and it is a plain class rather than view state on purpose:
// flipping a piece of @State to track "busy" invalidates the toolbar, which is
// the last thing you want mid-animation. This is checkable without a redraw.
//
// It previously sat behind a hard `.disabled` block on every bar button, because
// `EditButton()` mutates editMode itself and no guard could intercept it. With
// the edit toggle written out by hand and routed through here, every bar control
// passes this check, and nothing needs disabling — so there is no
// UIBarButtonItem.isEnabled left to be stranded by a bar rebuild.
final class ToolbarTapGate {
	private var _openAt: Date = .distantPast

	/// Returns true and closes the gate, or returns false if it is still shut.
	func allow(for interval: TimeInterval = 0.45) -> Bool {
		let now = Date()
		guard now >= _openAt else { return false }
		_openAt = now.addingTimeInterval(interval)
		return true
	}
}

// The Select All indicator, drawn from primitive shapes instead of SF Symbols.
//
// `checkmark.circle.fill` is a multi-layer symbol: a filled disc with the
// checkmark punched through it. Swapping it for `circle` hands UIKit a symbol
// transition to run, and interrupting that can leave the disc drawn with the
// checkmark layer missing (the solid blob) or with every layer gone (the blank
// button). Three plain shapes have no shared symbol machinery to catch halfway.
//
// Scope note: this is used ONLY by the toolbar button. It was briefly used by the
// list rows as well, which made the bug easier to hit rather than harder — three
// vector layers per row is more drawing work than one cached symbol bitmap, and
// with 80-odd rows redrawing at once that widened the window instead of closing
// it. The rows are back on plain SF Symbols.
struct SelectionCheckIcon: View {
	let isSelected: Bool
	var diameter: CGFloat = 21
	var ringColor: Color = .accentColor
	var fillColor: Color = .accentColor

	var body: some View {
		// All three layers are always present; only opacity changes, so the view's
		// identity never changes and there is no add/remove for SwiftUI to animate.
		ZStack {
			Circle()
				.strokeBorder(ringColor, lineWidth: max(1.4, diameter * 0.085))
				.opacity(isSelected ? 0 : 1)

			Circle()
				.fill(fillColor)
				.opacity(isSelected ? 1 : 0)

			Image(systemName: "checkmark")
				.font(.system(size: diameter * 0.5, weight: .heavy))
				.foregroundStyle(Color(uiColor: .systemBackground))
				.opacity(isSelected ? 1 : 0)
		}
		.frame(width: diameter, height: diameter)
		// Refuses animations inherited from the edit-mode transition or from the
		// list's own batch update, which `.animation(nil, value:)` does not.
		.transaction { transaction in
			transaction.animation = nil
			transaction.disablesAnimations = true
		}
	}
}

// MARK: - View
struct LibraryView: View {
	@StateObject var downloadManager = DownloadManager.shared
	@StateObject private var _exportManager = BulkExportManager()
	@AppStorage("Feather.useLastExportLocation") private var _useLastExportLocation: Bool = false
	
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
	
	// Not @State-observed for a value change; it is only ever read from inside
	// button actions, so it never needs to invalidate the view.
	@State private var _tapGate = ToolbarTapGate()

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
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
		// `animation: .snappy` was removed here. A fetch change (e.g. an app
		// landing at import completion) was committing an animated UICollectionView
		// batch update on the main thread; with a concurrent import still pushing
		// progress updates, that spring animation could run long enough to trip the
		// 10s scene-update watchdog (0x8BADF00D). A plain, non-animated update is cheap.
	) private var _signedApps: FetchedResults<Signed>
	
	@FetchRequest(
		entity: Imported.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)]
		// See the note on `_signedApps` above — animation removed for the same reason.
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
									isSelected: _selectedApps.contains(app.uuid ?? ""),
									onToggleSelection: { _toggleSelection(for: app) }
								)
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
									isSelected: _selectedApps.contains(app.uuid ?? ""),
									onToggleSelection: { _toggleSelection(for: app) }
								)
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
                    _editButton
                    if _isEditMode.isEditing {
                        _selectAllButton
                    }
                }
                // This group is ALWAYS here, in edit mode or out of it. It used
                // to be `if isEditing { ToolbarItemGroup(...) } else {
                // NBToolbarMenu(...) }` — two different toolbar *items* trading
                // places. SwiftUI maps each toolbar item onto a real
                // UIBarButtonItem, and when items are added and removed while
                // the bar is mid-animation (which is exactly what entering and
                // leaving edit mode does) the mapping can go wrong: an item is
                // dropped and never comes back, or an old one is left on screen
                // detached from the view that made it — a filled-in blob that no
                // longer responds to taps. Keeping one stable group and swapping
                // its contents means the bar never has to add or remove a slot.
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if _isEditMode.isEditing {
                        if _selectedTab == 0 {
                            _barButton("signature", enabled: !_selectedApps.isEmpty) {
                                _bulkSignRequest = BulkSignRequest(apps: _resolveSelectedApps(), signAndInstall: false)
                            }
                            _barButton("arrow.down.app", enabled: !_selectedApps.isEmpty) {
                                _bulkSignRequest = BulkSignRequest(apps: _resolveSelectedApps(), signAndInstall: true)
                            }
                        } else {
                            _barButton("square.and.arrow.down", enabled: !_selectedApps.isEmpty) {
                                InstallSession.shared.start(apps: _resolveSelectedApps())
                            }
                        }

                        _barButton(
                            "square.and.arrow.up",
                            enabled: !_selectedApps.isEmpty && !_exportManager.isExporting
                        ) {
                            _exportManager.start(apps: _resolveSelectedApps())
                        }

                        _barButton("trash", enabled: !_selectedApps.isEmpty) {
                            _bulkDeleteSelectedApps()
                        }
                    } else {
                        Menu {
                            _importActions()
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
			}
            .environment(\.editMode, $_isEditMode)
            .overlay {
                if _exportManager.isExporting {
                    ZStack {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        BulkExportProgressView(manager: _exportManager)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: _exportManager.isExporting)
            .sheet(isPresented: $_exportManager.readyToPick) {
                FileExporterRepresentableView(
                    urlsToExport: _exportManager.exportURLs,
                    asCopy: true,
                    useLastLocation: _useLastExportLocation,
                    onCompletion: { _ in _exportManager.finishPicking() }
                )
                .onDisappear { _exportManager.finishPicking() }
            }
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
            // Clear synchronously and without animation. Leaving edit mode
            // already makes SwiftUI push an editing-state change through
            // UICollectionView (performUpdates(_:shouldSetEditing:)); adding an
            // animated mass-deselect on top of that in the same pass is what
            // turned one tap into a multi-second main-thread batch update.
            if !state.isEditing, !_selectedApps.isEmpty {
                _selectedApps.removeAll()
            }
        }
        .onChange(of: _selectedTab) { _ in
            // Drop out of edit mode when the tab changes. The trailing buttons
            // differ per tab (Sign + Sign & Install on Downloaded, Install on
            // Signed), so switching tabs while editing made the toolbar swap its
            // buttons out from under itself. That happens automatically after a
            // bulk sign finishes — the notification below flips you to the Signed
            // tab — which is one of the moments a button would come back stuck or
            // missing. The selection was already tab-scoped, so nothing useful is
            // lost by clearing it here.
            if _isEditMode.isEditing {
                _isEditMode = .inactive
            }
            if !_selectedApps.isEmpty {
                _selectedApps.removeAll()
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

    // Replaces `EditButton()`. Not a style preference: `EditButton` is SwiftUI's
    // own control and its action mutates the editMode environment value
    // directly, so there is no closure to put a re-entrancy guard in. It was the
    // one bar control `_tapGate` could not see, and the only reason the whole
    // toolbar used to be `.disabled` for a second after every tap. Toggling the
    // state here by hand puts it behind the same gate as everything else, which
    // is what lets `.disabled` — and the UIKit enabled-state that gets stranded
    // with it — disappear from this file entirely.
    //
    // Longer than the 0.45s default because entering and leaving edit mode is a
    // heavier transition than a selection change: UICollectionView runs its own
    // setEditing pass underneath.
    //
    // The one thing given up is `EditButton`'s system-localized Edit/Done.
    private var _editButton: some View {
        Button {
            guard _tapGate.allow(for: 0.8) else { return }
            _isEditMode = _isEditMode.isEditing ? .inactive : .active
        } label: {
            // `String.localized` and `verbatim:` are both spelled out on purpose.
            // Bare `.localized` is ambiguous here — String and LocalizedStringKey
            // both provide it — and `Text` is overloaded on exactly that pair, so
            // the ternary has nothing to infer from. The lookup has already
            // happened by then, hence `verbatim:` rather than a second one.
            Text(verbatim: _isEditMode.isEditing ? String.localized("Done") : String.localized("Edit"))
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    // A nav-bar button that never uses `.disabled()`. Enabled/disabled is real
    // UIKit state living on the bar button item, and it is one of the things
    // that gets stranded when the bar is rebuilt mid-animation — the button
    // stays greyed out and untappable until the app is relaunched, even though
    // the selection it is watching has changed. Dimming the icon and refusing
    // the tap inside the action looks identical and has no UIKit state to get
    // stuck in. `_tapGate` is what actually drops a too-fast second tap.
    @ViewBuilder
    private func _barButton(
        _ systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard enabled, _tapGate.allow() else { return }
            action()
        } label: {
            Image(systemName: systemImage)
                .opacity(enabled ? 1 : 0.3)
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    // Select All / Deselect All. See SelectionCheckIcon for why this is drawn
    // from shapes rather than swapped between two SF Symbols.
    private var _selectAllButton: some View {
        Button {
            // Two guards, and the second one is the important one: a tap that
            // arrives while the previous one is still settling is dropped on the
            // floor rather than restarting the transition halfway through it.
            guard !_currentTabUUIDs.isEmpty, _tapGate.allow() else { return }
            _toggleSelectAll()
        } label: {
            SelectionCheckIcon(isSelected: _allCurrentTabSelected)
                .opacity(_currentTabUUIDs.isEmpty ? 0.3 : 1)
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private func _toggleSelectAll() {
        let ids = _currentTabUUIDs
        // No withAnimation: this mutates every row at once, and animating that
        // in a List means a spring-animated batch update over the whole set.
        if _allCurrentTabSelected {
            _selectedApps.subtract(ids)
        } else {
            _selectedApps.formUnion(ids)
        }
    }

    private func _toggleSelection(for app: AppInfoPresentable) {
        guard let uuid = app.uuid else { return }
        if _selectedApps.contains(uuid) {
            _selectedApps.remove(uuid)
        } else {
            _selectedApps.insert(uuid)
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
		guard !appsToDelete.isEmpty else { return }
		
		// Resolve every target up front instead of scanning both FetchedResults
		// once per selected UUID — that was O(selected x apps) with a Core Data
		// fault on each probe.
		var targets: [AppInfoPresentable] = []
		for app in _signedApps where appsToDelete.contains(app.uuid ?? "") {
			targets.append(app)
		}
		for app in _importedApps where appsToDelete.contains(app.uuid ?? "") {
			targets.append(app)
		}
		
		// No withAnimation. Each delete fires a @FetchRequest change, so
		// animating the loop meant N spring-animated List batch updates
		// stacked inside one 0.5s block — with the bundle deletion happening
		// on the main thread in between. That is the watchdog stack.
		_selectedApps.removeAll()
		for app in targets {
			Storage.shared.deleteApp(for: app)
		}
	}
}

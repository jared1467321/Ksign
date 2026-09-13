//
//  ArchiveView.swift
//  Feather
//
//  Created by samara on 6.05.2025.
//

import SwiftUI
import ASignArchiveKit
import NimbleViews

struct ArchiveView: View {
	// The old UI defaulted to standard compression, which was never what actually happened.
	// `@AppStorage` only writes its default once the control is touched, and
	// `ArchiveHandler.getCompressionLevel()` reads the key with
	// `UserDefaults.integer(forKey:)` — which returns 0, i.e. no compression,
	// for a key that was never written. So this screen claimed "Default"
	// while installs were archiving uncompressed. Uncompressed is the right
	// behaviour for a payload going over loopback or USB, so the label moves
	// to match the behaviour rather than the other way round.
	@AppStorage("Feather.compressionLevel") private var _compressionLevel: Int = ASignArchiveCompression.none.rawValue
	@AppStorage("Feather.useShareSheetForArchiving") private var _useShareSheet: Bool = true
	@AppStorage("Feather.useLastExportLocation") private var _useLastExportLocation: Bool = false
	@AppStorage("Feather.extractionLibrary") private var _extractionLibrary: String = ArchiveExtractionLibrary.miniZip
    
    var body: some View {
		NBList(.localized("Archive & Extraction")) {
			Section {
				Picker(.localized("Compression Level"), systemImage: "archivebox", selection: $_compressionLevel) {
					ForEach(ASignArchiveCompression.allCases, id: \.rawValue) { level in
						// Tagged with the raw value, not the case. The binding is an
						// `Int`, so tagging with the enum itself meant no tag ever
						// matched the selection and the picker couldn't be changed.
						Text(level.label).tag(level.rawValue)
					}
				}
			}
			
			Section {
				Toggle(.localized("Show Sheet when Exporting"), systemImage: "square.and.arrow.up", isOn: $_useShareSheet)
			} footer: {
				Text(.localized("Toggling show sheet will present a share sheet after exporting to your files."))
			}
            
            Section {
                Toggle(.localized("Use last copied location"), systemImage: "clock.arrow.circlepath", isOn: $_useLastExportLocation)
            } footer: {
                Text(.localized("Whether to remember the last location where a file was copied/moved to or use Ksign's documents folder as default."))
            }

            Section {
                Picker(.localized("Extraction Library"), systemImage: "archivebox.circle.fill", selection: $_extractionLibrary) {
                    ForEach(Options.extractionLibraryValues, id: \.self) { value in
                        Text(value).tag(value)
                    }
                }
            } footer: {
                Text("minizip-ng is the default archive engine. ZIPFoundation remains available as an alternative compatibility engine.")
            }
		}
		.onAppear {
			ArchiveExtractionLibrary.migrateStoredPreference()
			_extractionLibrary = ArchiveExtractionLibrary.normalized(_extractionLibrary)
		}
    }
}

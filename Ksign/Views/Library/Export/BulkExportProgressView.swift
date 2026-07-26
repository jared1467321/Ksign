//
//  BulkExportProgressView.swift
//  Ksign
//
//  Small progress card shown while a batch of apps is being archived for
//  export. Presented as an overlay (not a sheet) so it never collides with the
//  document picker that follows.
//

import SwiftUI
import NimbleViews

struct BulkExportProgressView: View {
	@ObservedObject var manager: BulkExportManager

	var body: some View {
		VStack(spacing: 14) {
			ProgressView(value: manager.overallProgress)
				.progressViewStyle(.linear)

			VStack(spacing: 6) {
				Text(.localized("Exporting %@ of %@", arguments: "\(min(manager.completed + 1, manager.total))", "\(manager.total)"))
					.font(.headline)

				HStack(spacing: 6) {
					ProgressView()
						.controlSize(.small)
					Text(manager.currentName)
						.font(.subheadline)
						.foregroundColor(.secondary)
						.lineLimit(1)
						.truncationMode(.middle)
				}
			}

			Button(role: .cancel) {
				manager.cancel()
			} label: {
				Text(.localized("Cancel"))
					.frame(maxWidth: .infinity)
			}
			.buttonStyle(.bordered)
		}
		.padding(20)
		.frame(maxWidth: 320)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
		.shadow(radius: 30)
		.padding()
	}
}

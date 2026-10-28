//
//  LogsView.swift
//  Asign
//
//  Created by Nagata Asami on 7/10/25.
//

import SwiftUI
import NimbleExtensions

struct LogsView: View {
	@ObservedObject var manager: LogsManager
	@State private var _isExporting = false
	@State private var _presentationID = UUID()

	private var _lastId: LogEntry.ID? { manager.entries.last?.id }

	var body: some View {
		NavigationStack {
			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 0) {
						ForEach(manager.entries) { entry in
							Text(entry.message)
                                .nbThemeForeground(.text)
								.font(.system(size: 12, weight: .regular, design: .monospaced))
								.textSelection(.enabled)
								.frame(maxWidth: .infinity, alignment: .leading)
								.padding(.horizontal)
								.padding(.vertical, 1)
								.id(entry.id)
						}
					}
				}
				.nbThemeCanvas(adaptsText: false)
                .safeAreaInset(edge: .bottom) {
                    if manager.hasOlderEntries {
                        Text("Showing recent logs. Export includes the full session.")
                            .font(.caption)
                            .nbThemeForeground(.textSecondary)
                            .padding(8)
                    }
                }
                .onAppear { if let id = _lastId { proxy.scrollTo(id, anchor: .bottom) } }
				.onChange(of: _lastId) { _ in
					if let id = _lastId { proxy.scrollTo(id, anchor: .bottom) }
				}
			}
			.toolbar {
				ToolbarItemGroup(placement: .navigationBarTrailing) {
					Button { exportLogs() } label: { Image(systemName: "square.and.arrow.up") }
						.disabled(manager.entries.isEmpty || _isExporting)
					Button { manager.clear() } label: { Image(systemName: "trash") }
					Button {
						if manager.isCapturing { manager.stopCapture() } else { manager.startCapture() }
					} label: {
						Image(systemName: manager.isCapturing ? "pause.circle" : "play.circle")
					}
				}
			}
		}
		.onAppear { manager.setPresented(true, owner: _presentationID) }
		.onDisappear { manager.setPresented(false, owner: _presentationID) }
	}

	private func exportLogs() {
		guard !_isExporting else { return }
		_isExporting = true
		Task { @MainActor in
			defer { _isExporting = false }
			do {
				let fileURL = try await manager.export()
				UIActivityViewController.show(activityItems: [fileURL])
			} catch {
				UIAlertController.showAlertWithOk(title: .localized("Export Failed"),
					message: error.localizedDescription)
			}
		}
	}
}



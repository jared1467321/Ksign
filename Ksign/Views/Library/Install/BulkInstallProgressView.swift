//
//  BulkInstallProgressView.swift
//  Ksign
//
//  Created by Nagata Asami on 27/1/26.
//

import SwiftUI
import NimbleViews
import IDeviceSwift

// One app's row in the install drawer.
//
// This used to own the entire install — the view model, the server, the stall
// watchdog, the queue slot, the progress poller — which meant the install only
// existed for as long as the row was on screen. All of that now lives in
// `InstallJob`, so this is just a picture of it and can be created, destroyed
// and recreated freely without disturbing anything.
struct BulkInstallProgressView: View {
	@ObservedObject var job: InstallJob

	var body: some View {
		VStack(spacing: 6) {
			// `.running` is the job holding a queue slot and actively
			// installing; `.queued` is still waiting its turn. That's exactly
			// the distinction the dot is there to make.
			InstallProgressView(
				app: job.app,
				viewModel: job.viewModel,
				isActive: job.phase == .running
			)

			if job.phase == .failed {
				Text(.localized("Failed"))
					.font(.caption2.weight(.medium))
					.foregroundStyle(.red)
			}
		}
		// Long press for the same two actions the Home Screen gives you. Using
		// the system context menu rather than a custom gesture means the lift,
		// the blur and the haptics all come for free and match the rest of iOS.
		.contextMenu {
			// A grid of icons at 54pt with a progress mask over them isn't
			// always enough to tell which app you long-pressed, and the two
			// actions underneath are destructive enough to be worth naming.
			// A Section header renders as the menu's title rather than
			// another tappable row.
			// Spelled `String.localized` rather than `.localized` for the same
			// reason the pill label is: both String and LocalizedStringKey
			// offer it, and Section's init is overloaded on exactly that.
			Section(job.app.name ?? String.localized("Unknown App")) {
				Button {
					InstallSession.shared.retry(job)
				} label: {
					Label(.localized("Retry"), systemImage: "arrow.clockwise")
				}

				Button(role: .destructive) {
					InstallSession.shared.remove(job)
				} label: {
					Label(.localized("Remove"), systemImage: "minus.circle")
				}
			}
		}
	}
}

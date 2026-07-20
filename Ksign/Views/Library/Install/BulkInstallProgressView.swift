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
			InstallProgressView(app: job.app, viewModel: job.viewModel)

			if job.phase == .failed {
				Text(.localized("Failed"))
					.font(.caption2.weight(.medium))
					.foregroundStyle(.red)
			}
		}
	}
}

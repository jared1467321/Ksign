//
//  BulkInstallProgressView.swift
//  Asign
//
//  Created by Nagata Asami on 27/1/26.
//

import SwiftUI
import NimbleViews
import IDeviceSwift
import NimbleExtensions

// One app's row in the install drawer.
//
// This used to own the entire install — the view model, the server, the stall
// watchdog, the queue slot, the progress poller — which meant the install only
// existed for as long as the row was on screen. All of that now lives in
// `InstallJob`, so this is just a picture of it and can be created, destroyed
// and recreated freely without disturbing anything.
struct BulkInstallProgressView: View {
	@ObservedObject var job: InstallJob
	@State private var showsSkipReason = false
	@State private var isVisible = false

	// Which dot this row gets.
	//
	// `phase` alone can't answer it. `.running` means the job holds a queue
	// slot, which covers everything from "still unzipping" to "iOS is
	// installing it right now" — so on a big batch it lit up every admitted
	// app at once and the dot stopped meaning anything. `batchRole` is what
	// actually knows: `.host`/`.member` are the manifest currently in flight,
	// while `.pending`/`.awaiting` are building or parked in the pool, and the
	// session folds those into the next manifest as soon as this one clears.
	//
	// `.none` — idevice, external server, or a retry that fell back to a solo
	// prompt — has no batching to speak of, so a running job there is simply
	// installing: orange, as before.
	private var _activity: InstallProgressView.Activity {
		guard job.phase == .running else { return .none }

		switch job.batchRole {
		case .pending, .awaiting: return .upcoming
		default: return .active
		}
	}

	var body: some View {
		VStack(spacing: 6) {
			if job.phase == .queued || !isVisible {
				// Waiting and retained offscreen apps need one cached image,
				// with no progress observer, mask or repeating animation.
				InstallStaticAppIcon(app: job.app)
					.equatable()
					.nbThemeOpacity(0.35)
					.frame(width: 54, height: 54)
					.scaleEffect(0.81)
			} else {
				InstallProgressView(
					app: job.app,
					viewModel: job.viewModel,
					activity: _activity,
					animatesIcon: _activity == .active
				)
			}

			if job.phase == .failed {
				Text(.localized("Failed"))
					.font(.caption2.weight(.medium))
					.nbThemeForeground(.danger)
			} else if job.phase == .skipped {
				Text("Skipped")
					.font(.caption2.weight(.medium))
					.nbThemeForeground(.warning)
			}
		}
		// Lazy grids retain cells after scrolling. Retained offscreen cells
		// must release progress observers and repeating icon animations.
		.onAppear { isVisible = true }
		.onDisappear { isVisible = false }
		// Finish the progress fill, then fade only this icon before retirement.
		// Moving all remaining queued icons is deliberately not animated.
		.opacity(job.phase == .completed ? 0 : 1)
		.animation(.easeOut(duration: 0.25).delay(1.25), value: job.phase == .completed)
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
                if job.skipReason != nil {
                    Button { showsSkipReason = true } label: {
                        Label("Why skipped?", systemImage: "info.circle")
                    }
                }
                if let metrics = job.viewModel.uploadMetrics {
                    Text("Upload: \(metrics.summary)")
                }
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
		.alert("Installation Skipped", isPresented: $showsSkipReason) {
			Button("OK", role: .cancel) { }
		} message: {
			Text(job.skipReason ?? "")
		}
	}
}

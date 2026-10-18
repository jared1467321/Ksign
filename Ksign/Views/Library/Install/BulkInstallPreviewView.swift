//
//  BulkInstallPreviewView.swift
//  Ksign
//
//  Created by Nagata Asami on 27/1/26.
//

import SwiftUI
import NimbleExtensions
import NimbleViews

// The grid of in-flight installs shown inside the drawer.
struct BulkInstallPreviewView: View {
	@State private var jobs = InstallSession.shared.jobs
	// The size of the batch when it started, which is *not* `jobs.count` —
	// finished apps are removed as they go.
	@State private var originalCount = InstallSession.shared.totalCount

	private let _columns = [GridItem(.adaptive(minimum: 80))]

	var body: some View {
		Group {
			// Deliberately branching on `originalCount`. If this flipped from
			// LazyVGrid to HStack partway through a batch (say, 4 apps dropping
			// to 3), SwiftUI would swap container types and rebuild every
			// remaining row. That's only cosmetic now that installs live in
			// `InstallJob` — back when the rows owned the installs it would
			// have restarted them.
			if originalCount <= 3 {
				HStack(spacing: 20) {
					ForEach(jobs) { job in
						BulkInstallProgressView(job: job)
							.padding(.horizontal)
					}
				}
			} else {
				LazyVGrid(columns: _columns, spacing: 20) {
					ForEach(jobs) { job in
						BulkInstallProgressView(job: job)
					}
				}
				.padding(.horizontal)
			}
		}
		.frame(maxWidth: .infinity, alignment: .center)
		.padding(.vertical, 24)
		// The sheet already supplies viewport-sized glass. A second live glass
		// surface here would grow to the height of the entire waiting queue.
		.nbThemeBackground(
			.elevated, opacity: 0.55,
			in: RoundedRectangle(cornerRadius: 22.5), supportsGloss: false
		)
		.nbThemeOverlay {
			RoundedRectangle(cornerRadius: 22.5)
				.fill(LinearGradient(
					colors: [.white.opacity(0.035), .clear],
					startPoint: .topLeading, endPoint: .bottomTrailing
				))
				.allowsHitTesting(false)
		}
		.nbThemeOverlay {
			RoundedRectangle(cornerRadius: 22.5)
				.nbThemeStroke(.text, opacity: 0.07, lineWidth: 0.5)
				.allowsHitTesting(false)
		}
		.padding(.horizontal)
		// Membership/layout changes are events. Numeric progress belongs to the
		// header and active rows, and never compares or republishes this array.
		.onReceive(InstallSession.shared.$jobs) { jobs = $0 }
		.onReceive(InstallSession.shared.$totalCount) { originalCount = $0 }
	}
}

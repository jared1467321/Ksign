//
//  BulkInstallPreviewView.swift
//  Ksign
//
//  Created by Nagata Asami on 27/1/26.
//

import SwiftUI
import NimbleViews

// The grid of in-flight installs shown inside the drawer.
struct BulkInstallPreviewView: View {
	var jobs: [InstallJob]
	// The size of the batch when it started, which is *not* `jobs.count` —
	// finished apps are removed as they go.
	var originalCount: Int

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
		.background(Color(UIColor.secondarySystemBackground))
		.cornerRadius(22.5)
		.padding(.horizontal)
	}
}

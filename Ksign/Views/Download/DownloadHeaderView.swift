//
//  DownloadHeaderView.swift
//  Feather
//
//  Created by samara on 16.05.2025.
//

import SwiftUI
import Combine

struct DownloadHeaderView: View {
	@ObservedObject var downloadManager: DownloadManager
	
	// Everything still to come after the one row on screen: the other imports
	// currently running, plus the rest of the batch that hasn't started yet.
	//
	// Previously this was just `manualDownloads.count - 1`, which only ever
	// saw what was in flight — and since bulk import runs two at a time, that
	// was permanently "+1" no matter how many apps you'd selected. Now a
	// 35-app import reads "+34" and counts down as they land.
	private var _remainingCount: Int {
		let inFlight = downloadManager.manualDownloads.count
		guard inFlight > 0 else { return 0 }
		return (inFlight - 1) + downloadManager.queuedImportCount
	}
	
	var body: some View {
		ZStack {
			if !downloadManager.manualDownloads.isEmpty {
				VStack {
					VStack(spacing: 12) {
						if let firstDownload = downloadManager.manualDownloads.first {
							DownloadItemView(download: firstDownload)
							
							if _remainingCount > 0 {
								HStack {
									Spacer()
									Text(verbatim: "+\(_remainingCount)")
										.font(.caption)
										.foregroundColor(.secondary)
										.contentTransition(.numericText())
										.padding(.vertical, 4)
								}
							}
						}
					}
					.padding(.horizontal)
				}
				.transition(.move(edge: .top).combined(with: .opacity))
			}
		}
		.animation(.spring(), value: downloadManager.manualDownloads.count)
		.animation(.spring(), value: downloadManager.queuedImportCount)
	}
}

struct DownloadItemView: View {
	let download: Download
	@State private var progress: Double = 0
	@State private var bytesDownloaded: Int64 = 0
	@State private var totalBytes: Int64 = 0
	@State private var unpackageProgress: Double = 0
	
	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(download.fileName)
				.font(.subheadline)
				.lineLimit(1)
			
			ProgressView(value: overallProgress)
				.progressViewStyle(.linear)
			
			HStack {
				Text(verbatim: "\(Int(overallProgress * 100))%")
					.contentTransition(.numericText())
				Spacer()
				if totalBytes > 0 {
					Text(verbatim: "\(formatByteCount(bytesDownloaded)) / \(formatByteCount(totalBytes))")
						.contentTransition(.numericText())
				}
			}
			.font(.caption)
			.foregroundColor(.secondary)
		}
		.padding(.vertical, 4)
		.onReceive(download.$progress) { self.progress = $0 }
		.onReceive(download.$bytesDownloaded) { self.bytesDownloaded = $0 }
		.onReceive(download.$totalBytes) { self.totalBytes = $0 }
		.onReceive(download.$unpackageProgress) { self.unpackageProgress = $0 }
	}
	
	private var overallProgress: Double {
		download.onlyArchiving
		? unpackageProgress
		: (0.3 * unpackageProgress) + (0.7 * progress)
	}
	
	private func formatByteCount(_ bytes: Int64) -> String {
		let formatter = ByteCountFormatter()
		formatter.allowedUnits = [.useAll]
		formatter.countStyle = .file
		return formatter.string(fromByteCount: bytes)
	}
}

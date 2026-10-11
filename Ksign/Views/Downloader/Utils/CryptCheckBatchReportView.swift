import Foundation
import SwiftUI
import NimbleViews

struct CryptCheckReport {
    let url: URL
    let encryptedCount: Int
    let possiblyEncryptedCount: Int

    var pauseReason: String? {
        if encryptedCount > 0 && possiblyEncryptedCount > 0 {
            return "Paused: encrypted and possibly encrypted files found"
        }
        if encryptedCount > 0 { return "Paused: encrypted file found" }
        if possiblyEncryptedCount > 0 { return "Paused: possibly encrypted file found" }
        return nil
    }
}

/// Keeps manual navigation separate from timed advances so a swipe always pauses.
struct CryptCheckBatchNavigation {
    private(set) var selectedIndex = 0
    private(set) var isRunning = false
    private(set) var message: String?
    private(set) var hasStarted = false
    private var acknowledgedIndex: Int?

    mutating func pause() {
        isRunning = false
    }

    mutating func select(_ index: Int) {
        guard index != selectedIndex else { return }
        pause()
        selectedIndex = index
        acknowledgedIndex = nil
        message = nil
    }

    mutating func start(reports: [CryptCheckReport]) {
        guard reports.indices.contains(selectedIndex) else { return }
        hasStarted = true
        // The first tap also checks the currently visible report. A subsequent
        // Resume acknowledges that finding and proceeds to the next report.
        if acknowledgedIndex != selectedIndex,
           let reason = reports[selectedIndex].pauseReason {
            acknowledgedIndex = selectedIndex
            message = reason
            isRunning = false
            return
        }
        guard selectedIndex + 1 < reports.count else {
            message = "Batch complete"
            isRunning = false
            return
        }
        message = nil
        isRunning = true
    }

    mutating func advance(reports: [CryptCheckReport]) {
        guard isRunning, selectedIndex + 1 < reports.count else {
            pause()
            return
        }
        selectedIndex += 1
        acknowledgedIndex = nil
        if let reason = reports[selectedIndex].pauseReason {
            acknowledgedIndex = selectedIndex
            message = reason
            isRunning = false
        } else if selectedIndex == reports.count - 1 {
            message = "Batch complete"
            isRunning = false
        }
    }
}

struct CryptCheckBatchReportView<ReportContent: View>: View {
    let title: String
    let reports: [CryptCheckReport]
    @ViewBuilder let reportContent: (CryptCheckReport) -> ReportContent

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigation = CryptCheckBatchNavigation()
    @State private var intervalSeconds = 3
    @State private var exportError: String?
    @State private var showExporter = false

    private struct AdvanceSchedule: Equatable {
        let isRunning: Bool
        let index: Int
        let seconds: Int
    }

    private var currentReportURL: URL? {
        guard reports.indices.contains(navigation.selectedIndex) else { return nil }
        return reports[navigation.selectedIndex].url
    }

    private var navigationTitle: String {
        reports.count > 1
            ? "\(title) \(navigation.selectedIndex + 1) of \(reports.count)"
            : title
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if reports.count > 1 {
                    batchControls
                    Divider()
                }
                TabView(selection: Binding(
                    get: { navigation.selectedIndex },
                    set: { navigation.select($0) }
                )) {
                    ForEach(Array(reports.enumerated()), id: \.offset) { index, report in
                        reportContent(report)
                            .ignoresSafeArea(edges: .bottom)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: reports.count > 1 ? .automatic : .never))
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        navigation.pause()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        navigation.pause()
                        guard let currentReportURL else { return }
                        do {
                            try ThemeReportBridge.shared.persistCurrentTheme(to: [currentReportURL])
                            showExporter = true
                        } catch {
                            exportError = error.localizedDescription
                        }
                    }
                    .disabled(currentReportURL == nil)
                }
            }
        }
        .task(id: AdvanceSchedule(
            isRunning: navigation.isRunning,
            index: navigation.selectedIndex,
            seconds: intervalSeconds
        )) {
            guard navigation.isRunning else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(intervalSeconds) * 1_000_000_000)
                try Task.checkCancellation()
                withAnimation(.easeInOut(duration: 0.25)) {
                    navigation.advance(reports: reports)
                }
            } catch {
                // Pausing, swiping, changing the interval, or leaving cancels the wait.
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { navigation.pause() }
        }
        .alert("Could Not Save Report", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .sheet(isPresented: $showExporter) {
            if let currentReportURL {
                FileExporterRepresentableView(
                    urlsToExport: [currentReportURL],
                    asCopy: true,
                    useLastLocation: false,
                    onCompletion: { _ in showExporter = false }
                )
            }
        }
        .onDisappear {
            navigation.pause()
            // Saving exports a copy; the generated reports remain temporary.
            Set(reports.map(\.url)).forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    private var batchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    if navigation.isRunning {
                        navigation.pause()
                    } else {
                        navigation.start(reports: reports)
                    }
                } label: {
                    Label(
                        navigation.isRunning ? "Pause" : (navigation.hasStarted ? "Resume" : "Auto-scroll"),
                        systemImage: navigation.isRunning ? "pause.fill" : "play.fill"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(navigation.message == "Batch complete")

                Spacer()
                Text("Every")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Interval", selection: $intervalSeconds) {
                    ForEach([1, 2, 3, 5, 10], id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Auto-scroll interval")
            }
            Text(navigation.message ?? (navigation.isRunning
                ? "Auto-scrolling · Report \(navigation.selectedIndex + 1) of \(reports.count)"
                : "Report \(navigation.selectedIndex + 1) of \(reports.count)"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

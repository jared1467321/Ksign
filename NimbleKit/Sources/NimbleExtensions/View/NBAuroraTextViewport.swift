import SwiftUI

private struct NBAuroraTextViewportKey: EnvironmentKey {
    static let defaultValue: NBAuroraTextViewport? = nil
}

extension EnvironmentValues {
    var nbAuroraTextViewport: NBAuroraTextViewport? {
        get { self[NBAuroraTextViewportKey.self] }
        set { self[NBAuroraTextViewportKey.self] = newValue }
    }
}

public extension View {
    /// Apply to a scrolling container, outside its row builder. Descendant
    /// adaptive text uses this viewport to suspend offscreen frame delivery.
    func nbThemeTextViewport() -> some View {
        modifier(NBAuroraTextViewportModifier())
    }
}

private struct NBAuroraTextViewportModifier: ViewModifier {
    @Environment(\.nbAuroraTextViewport) private var parent
    @ObservedObject private var session = AuroraSession.shared
    @State private var measurement = NBAuroraTextViewportMeasurement()
    @State private var measurementID = UUID()
    @State private var completedMeasurementID: UUID?
    @State private var appeared = false

    func body(content: Content) -> some View {
        let request = measurementID
        content
            .environment(\.nbAuroraTextViewport,
                         NBAuroraTextViewport(frame: measurement.frame, window: measurement.window, parent: parent,
                                              measurementID: completedMeasurementID))
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: {
                measurement.receiveFrame($0)
                // Pair a changed SwiftUI frame with a fresh window report.
                // Reusing an old UIKit origin here can produce false clipping.
                requestMeasurement()
            }
            .background {
                // One window-coordinate reader for the list, rather than one
                // UIKit anchor for every title, subtitle and chevron.
                AuroraViewportReader(reportID: request) { viewport in
                    guard appeared, measurementID == request else { return }
                    measurement.receiveWindow(origin: viewport.origin, size: viewport.size)
                    if NBAuroraTextViewport(frame: measurement.frame, window: measurement.window, parent: parent).isReady {
                        completedMeasurementID = request
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onAppear { appeared = true; requestMeasurement() }
            .onDisappear { appeared = false }
            .onChange(of: parent) { _ in requestMeasurement() }
            .onChange(of: session.measurementRevision) { _ in requestMeasurement() }
    }

    private func requestMeasurement() {
        guard appeared else { return }
        measurementID = UUID()
    }
}

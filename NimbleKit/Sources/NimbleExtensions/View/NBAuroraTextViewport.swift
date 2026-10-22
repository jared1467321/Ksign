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
    @State private var frame = CGRect.zero
    @State private var window: CGRect?
    @State private var measurementID = UUID()
    @State private var completedMeasurementID: UUID?
    @State private var appeared = false

    func body(content: Content) -> some View {
        let request = measurementID
        content
            .environment(\.nbAuroraTextViewport,
                         NBAuroraTextViewport(frame: frame, window: window, parent: parent,
                                              measurementID: completedMeasurementID))
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: {
                frame = $0
                // Pair a changed SwiftUI frame with a fresh window report.
                // Reusing an old UIKit origin here can produce false clipping.
                requestMeasurement()
            }
            .background {
                // One window-coordinate reader for the list, rather than one
                // UIKit anchor for every title, subtitle and chevron.
                GeometryReader { proxy in
                    AuroraViewportReader(reportID: request) { viewport in
                        guard appeared, measurementID == request else { return }
                        // Read both coordinate systems together after return.
                        frame = proxy.frame(in: .global)
                        updateWindow(viewport)
                        if NBAuroraTextViewport(frame: frame, window: window, parent: parent).isReady {
                            completedMeasurementID = request
                        }
                    }
                }
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

    private func updateWindow(_ viewport: AuroraViewport) {
        guard !frame.isEmpty else { return }
        window = CGRect(x: frame.minX - viewport.origin.x,
                        y: frame.minY - viewport.origin.y,
                        width: viewport.size.width, height: viewport.size.height)
    }
}

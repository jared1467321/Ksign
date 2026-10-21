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
    @State private var pendingViewport: AuroraViewport?
    @State private var measurementID = UUID()

    func body(content: Content) -> some View {
        content
            .environment(\.nbAuroraTextViewport,
                         NBAuroraTextViewport(frame: frame, window: window, parent: parent))
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: {
                frame = $0
                if window == nil, let pendingViewport { updateWindow(pendingViewport) }
            }
            .background {
                // One window-coordinate reader for the list, rather than one
                // UIKit anchor for every title, subtitle and chevron.
                GeometryReader { proxy in
                    AuroraViewportReader { viewport in
                        // Read both coordinate systems together after return.
                        frame = proxy.frame(in: .global)
                        pendingViewport = viewport
                        updateWindow(viewport)
                    }
                }
                .id(measurementID)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onAppear { measurementID = UUID() }
            .onChange(of: session.measurementRevision) { _ in measurementID = UUID() }
    }

    private func updateWindow(_ viewport: AuroraViewport) {
        guard !frame.isEmpty else { return }
        window = CGRect(x: frame.minX - viewport.origin.x,
                        y: frame.minY - viewport.origin.y,
                        width: viewport.size.width, height: viewport.size.height)
    }
}

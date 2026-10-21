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
    private struct Geometry: Equatable {
        let frame: CGRect
        let clipping: CGRect
    }

    @Environment(\.nbAuroraTextViewport) private var parent
    @ObservedObject private var session = AuroraSession.shared
    @State private var geometry = Geometry(frame: .zero, clipping: .null)
    @State private var window: CGRect?
    @State private var pendingViewport: AuroraViewport?

    func body(content: Content) -> some View {
        let clipping = parent.map { geometry.clipping.intersection($0.clipping) } ?? geometry.clipping
        content
            .environment(\.nbAuroraTextViewport,
                         NBAuroraTextViewport(clipping: clipping, window: window ?? parent?.window))
            .onGeometryChange(for: Geometry.self) { proxy in
                // GeometryProxy stays inside the measurement callback.
                let frame = proxy.frame(in: .global)
                let insets = proxy.safeAreaInsets
                return Geometry(frame: frame,
                                clipping: CGRect(x: frame.minX + insets.leading,
                                                 y: frame.minY + insets.top,
                                                 width: max(0, frame.width - insets.leading - insets.trailing),
                                                 height: max(0, frame.height - insets.top - insets.bottom)))
            } action: {
                geometry = $0
                if window == nil, let pendingViewport { updateWindow(pendingViewport) }
            }
            .background {
                // One window-coordinate reader for the list, rather than one
                // UIKit anchor for every title, subtitle and chevron.
                GeometryReader { proxy in
                    AuroraViewportReader { viewport in
                        // Read both coordinate systems together after return.
                        geometry = measure(proxy)
                        pendingViewport = viewport
                        updateWindow(viewport)
                    }
                }
                .id(session.measurementRevision)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }

    private func measure(_ proxy: GeometryProxy) -> Geometry {
        let frame = proxy.frame(in: .global)
        let insets = proxy.safeAreaInsets
        return Geometry(frame: frame,
                        clipping: CGRect(x: frame.minX + insets.leading,
                                         y: frame.minY + insets.top,
                                         width: max(0, frame.width - insets.leading - insets.trailing),
                                         height: max(0, frame.height - insets.top - insets.bottom)))
    }

    private func updateWindow(_ viewport: AuroraViewport) {
        guard !geometry.frame.isEmpty else { return }
        window = CGRect(x: geometry.frame.minX - viewport.origin.x,
                        y: geometry.frame.minY - viewport.origin.y,
                        width: viewport.size.width, height: viewport.size.height)
    }
}

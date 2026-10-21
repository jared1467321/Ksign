import SwiftUI

private struct NBAuroraTextRowKey: EnvironmentKey {
    // Type erasure keeps the environment usable on iOS 16, where shader ink
    // and the tracker are unavailable and the existing difference fill is used.
    static var defaultValue: AnyObject? { nil }
}

extension EnvironmentValues {
    var nbAuroraTextRow: AnyObject? {
        get { self[NBAuroraTextRowKey.self] }
        set { self[NBAuroraTextRowKey.self] = newValue }
    }
}

public extension View {
    /// Share scrolling geometry between adaptive labels inside a list row.
    /// Install within nbThemeTextViewport(); each label retains its own paint.
    @ViewBuilder
    func nbThemeTextRow() -> some View {
        if #available(iOS 17.0, tvOS 17.0, *) {
            modifier(NBAuroraTextRowModifier())
        } else {
            self
        }
    }
}

@available(iOS 17.0, tvOS 17.0, *)
private struct NBAuroraTextRowModifier: ViewModifier {
    @StateObject private var row = NBAuroraTextRowTracker()
    @ObservedObject private var session = AuroraSession.shared
    @Environment(\.nbAuroraTextViewport) private var viewport
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("Feather.auroraBackground") private var aurora = true
    @AppStorage("Feather.auroraAdaptiveText") private var adaptive = true
    @State private var appeared = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if aurora && adaptive && !reduceTransparency && contrast != .increased && viewport != nil {
            tracked(content)
        } else {
            content
        }
    }

    private func tracked(_ content: Content) -> some View {
        content
            .environment(\.nbAuroraTextRow, row)
            .coordinateSpace(name: row.coordinateSpaceID)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onGeometryChange(for: NBAuroraTextRowGeometry.self) { measure($0) }
                            action: { row.move(to: $0) }
                        .onChange(of: viewport) { _ in
                            row.move(to: measure(proxy))
                        }
                }
                .id(session.measurementRevision)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onAppear { appeared = true; configure(refresh: true) }
            .onDisappear { appeared = false; configure() }
            .onChange(of: viewport) { _ in configure() }
            .onChange(of: scenePhase) { phase in configure(refresh: phase == .active) }
            .onChange(of: reduceMotion) { _ in configure() }
            .onChange(of: session.identity.shaderIdentity) { _ in configure(refresh: true) }
    }

    private func measure(_ proxy: GeometryProxy) -> NBAuroraTextRowGeometry {
        let frame = proxy.frame(in: .global)
        if let viewport, let window = viewport.window,
           !NBAuroraTextVisibility.intersects(frame, window: window, clipping: viewport.clipping) {
            // Retained offscreen rows report one stable sentinel.
            return NBAuroraTextRowGeometry(frame: .null, size: .zero)
        }
        return NBAuroraTextRowGeometry(frame: frame, size: proxy.size)
    }

    private func configure(refresh: Bool = false) {
        row.configure(viewport: viewport, active: appeared && scenePhase == .active,
                      reduceMotion: reduceMotion, refresh: refresh)
    }
}

@available(iOS 17.0, tvOS 17.0, *)
struct NBAuroraRowTextShaderScope<Content: View>: View {
    @StateObject private var client = NBAuroraRowTextClient()
    @ObservedObject private var session = AuroraSession.shared
    let content: Content
    let primary: NBThemeColor
    let secondary: NBThemeColor?
    let adaptsPrimary: Bool
    let adaptsSecondary: Bool
    let row: NBAuroraTextRowTracker

    var body: some View {
        NBAuroraRowMappedForeground(content: content, primary: primary, secondary: secondary,
                                    adaptsPrimary: adaptsPrimary, adaptsSecondary: adaptsSecondary,
                                    identity: session.identity.shaderIdentity,
                                    placement: client.placement, paint: client.lease.paint)
            // These coordinates stay constant while the row scrolls. Changes
            // to wrapping, layout or edit controls still remeasure each label.
            .background {
                Color.clear
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(row.coordinateSpaceID)) }
                        action: { row.measure(client, localFrame: $0) }
                    .id(session.measurementRevision)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onAppear { row.setVisible(client, true) }
            .onDisappear { row.setVisible(client, false) }
    }
}

@available(iOS 17.0, tvOS 17.0, *)
private struct NBAuroraRowMappedForeground<Content: View>: View {
    let content: Content
    let primary: NBThemeColor
    let secondary: NBThemeColor?
    let adaptsPrimary: Bool
    let adaptsSecondary: Bool
    let identity: NBAuroraShaderIdentity
    @ObservedObject var placement: NBAuroraRowTextPlacement
    let paint: NBAuroraInkPaint

    var body: some View {
        NBAuroraMappedForeground(content: content, primary: primary, secondary: secondary,
                                 adaptsPrimary: adaptsPrimary, adaptsSecondary: adaptsSecondary,
                                 bounds: placement.bounds, identity: identity, paint: paint)
    }
}

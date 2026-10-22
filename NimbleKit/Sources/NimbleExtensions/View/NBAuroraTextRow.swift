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
    @State private var remeasurement: UUID?

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
            .onGeometryChange(for: NBAuroraTextRowGeometry.self) { proxy in
                NBAuroraTextRowGeometry(frame: proxy.frame(in: .global), size: proxy.size)
                    .clipped(to: viewport)
            } action: { receive($0) }
            .background {
                if let request = remeasurement {
                    // Keep recovery probes out of the normal scrolling path.
                    GeometryReader { proxy in
                        let measured = NBAuroraTextRowGeometry(frame: proxy.frame(in: .global), size: proxy.size)
                            .clipped(to: viewport)
                        Color.clear.task(id: request) {
                            guard remeasurement == request else { return }
                            receive(measured)
                        }
                    }
                    .id(request)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onAppear { appeared = true; configure(refresh: true); requestMeasurement() }
            .onDisappear { appeared = false; configure(); remeasurement = nil }
            .onChange(of: viewport) { _ in configure(); requestMeasurement() }
            .onChange(of: session.measurementRevision) { _ in requestMeasurement() }
            .onChange(of: scenePhase) { phase in configure(refresh: phase == .active) }
            .onChange(of: reduceMotion) { _ in configure() }
            .onChange(of: session.identity.shaderIdentity) { _ in configure(refresh: true) }
    }

    private func configure(refresh: Bool = false) {
        row.configure(viewport: viewport, active: appeared && scenePhase == .active,
                      reduceMotion: reduceMotion, refresh: refresh)
    }

    private func requestMeasurement() {
        remeasurement = appeared && viewport?.isReady == true ? UUID() : nil
    }

    private func receive(_ geometry: NBAuroraTextRowGeometry) {
        row.move(to: geometry)
        if geometry.frame.isNull || (!geometry.frame.isEmpty && geometry.size.width > 0 && geometry.size.height > 0) {
            remeasurement = nil
        }
    }
}

@available(iOS 17.0, tvOS 17.0, *)
struct NBAuroraRowTextShaderScope<Content: View>: View {
    @StateObject private var client = NBAuroraRowTextClient()
    @ObservedObject private var session = AuroraSession.shared
    @Environment(\.nbAuroraTextViewport) private var viewport
    @State private var remeasurement: UUID?
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
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(row.coordinateSpaceID)) }
                action: { receive($0) }
            .background {
                if let request = remeasurement {
                    GeometryReader { proxy in
                        let measured = proxy.frame(in: .named(row.coordinateSpaceID))
                        Color.clear.task(id: request) {
                            guard remeasurement == request else { return }
                            receive(measured)
                        }
                    }
                    .id(request)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onChange(of: viewport) { _ in requestMeasurement() }
            .onChange(of: session.measurementRevision) { _ in requestMeasurement() }
            .onAppear { row.setVisible(client, true); requestMeasurement() }
            .onDisappear { row.setVisible(client, false); remeasurement = nil }
    }

    private func requestMeasurement() {
        remeasurement = client.visible && viewport?.isReady == true ? UUID() : nil
    }

    private func receive(_ frame: CGRect) {
        row.measure(client, localFrame: frame)
        if !frame.isNull && !frame.isEmpty { remeasurement = nil }
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

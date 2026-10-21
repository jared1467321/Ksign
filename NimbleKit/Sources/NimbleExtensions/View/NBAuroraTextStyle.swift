import SwiftUI

/// Adapt only foreground paint. Shader fills keep the complementary hue vivid
/// while controlling brightness independently of the aurora's exposure.
struct NBAuroraTextStyleModifier: ViewModifier {
    @AppStorage("Feather.auroraBackground") private var aurora = true
    @AppStorage("Feather.auroraAdaptiveText") private var adaptiveText = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nbAuroraTextRow) private var textRow

    let primary: NBThemeColor
    var secondary: NBThemeColor? = nil
    var adaptsPrimary = true
    var adaptsSecondary = true

    private var enabled: Bool {
        aurora && adaptiveText && !reduceTransparency && contrast != .increased
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled && (adaptsPrimary || (secondary != nil && adaptsSecondary)),
           #available(iOS 17.0, tvOS 17.0, *) {
            if let textRow = textRow as? NBAuroraTextRowTracker {
                NBAuroraRowTextShaderScope(
                    content: content, primary: primary, secondary: secondary,
                    adaptsPrimary: adaptsPrimary, adaptsSecondary: adaptsSecondary,
                    row: textRow
                )
            } else {
                NBAuroraTextShaderScope(
                    content: content, primary: primary, secondary: secondary,
                    adaptsPrimary: adaptsPrimary, adaptsSecondary: adaptsSecondary
                )
            }
        } else if let secondary {
            content.foregroundStyle(legacyInk(primary, adapts: adaptsPrimary),
                                    legacyInk(secondary, adapts: adaptsSecondary))
        } else {
            content.foregroundStyle(legacyInk(primary, adapts: adaptsPrimary))
        }
    }

    // iOS 16 has no shader fills. Retain full-strength per-pixel inversion there
    // rather than flattening the response into the rejected pastel palette.
    private func legacyInk(_ fallback: NBThemeColor, adapts: Bool) -> AnyShapeStyle {
        guard enabled && adapts && fallback.alpha > 0 else {
            return AnyShapeStyle(fallback.color)
        }
        return AnyShapeStyle(
            Color.white.opacity(fallback.alpha)
                .blendMode(.difference)
                .shadow(.drop(color: .black.opacity(0.95), radius: 0.65))
                .shadow(.drop(color: .black.opacity(0.8), radius: 1.2, y: 0.5))
        )
    }
}

@available(iOS 17.0, tvOS 17.0, *)
private struct NBAuroraTextShaderScope<Content: View>: View {
    @ObservedObject private var session = AuroraSession.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nbAuroraTextViewport) private var scrollViewport
    @StateObject private var lease = NBAuroraInkLease()
    @State private var frame = CGRect.zero
    @State private var viewport: AuroraViewport?
    @State private var viewportFrame = CGRect.zero
    @State private var isVisible = false
    @State private var isInViewport = false

    let content: Content
    let primary: NBThemeColor
    let secondary: NBThemeColor?
    let adaptsPrimary: Bool
    let adaptsSecondary: Bool

    var body: some View {
        let window = windowFrame
        let size = window?.size ?? CGSize(width: max(1, frame.width), height: max(1, frame.height))
        let origin = CGPoint(x: frame.minX - (window?.minX ?? 0),
                             y: frame.minY - (window?.minY ?? 0))
        let bounds = CGRect(x: -origin.x, y: -origin.y, width: size.width, height: size.height)

        NBAuroraMappedForeground(content: content, primary: primary, secondary: secondary,
                                 adaptsPrimary: adaptsPrimary, adaptsSecondary: adaptsSecondary,
                                 bounds: bounds, identity: session.identity.shaderIdentity,
                                 paint: lease.paint)
            .onGeometryChange(for: CGRect.self) { proxy in
                let rect = proxy.frame(in: .global)
                guard let scrollViewport else { return rect }
                guard let window = scrollViewport.window,
                      NBAuroraTextVisibility.intersects(rect, window: window,
                                                       clipping: scrollViewport.clipping) else { return .null }
                return rect
            } action: { measured in
                // All offscreen positions resolve to the same value, so cached
                // rows do not update SwiftUI state on every scroll offset.
                isInViewport = !measured.isNull
                if isInViewport {
                    frame = measured
                    if viewport != nil && viewportFrame.isEmpty { viewportFrame = measured }
                }
                updateLease()
            }
            .background {
                if scrollViewport == nil {
                    AuroraViewportReader {
                        viewport = $0
                        viewportFrame = frame
                        updateLease()
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onAppear { isVisible = true; updateLease(refresh: true) }
            .onDisappear { isVisible = false; updateLease() }
            .onChange(of: scenePhase) { phase in updateLease(refresh: phase == .active) }
            .onChange(of: reduceMotion) { _ in updateLease() }
            .onChange(of: session.identity.shaderIdentity) { _ in updateLease(refresh: true) }
            .onChange(of: scrollViewport) { _ in updateLease() }
    }

    private var windowFrame: CGRect? {
        if let scrollViewport { return scrollViewport.window }
        return viewport.map {
            CGRect(x: viewportFrame.minX - $0.origin.x, y: viewportFrame.minY - $0.origin.y,
                   width: $0.size.width, height: $0.size.height)
        }
    }

    private func updateLease(refresh: Bool = false) {
        let intersects = windowFrame.map {
            NBAuroraTextVisibility.intersects(frame, window: $0, clipping: scrollViewport?.clipping)
        } ?? false
        let active = isVisible && isInViewport && intersects && scenePhase == .active
        guard lease.active != active || lease.reduceMotion != reduceMotion || (refresh && active) else { return }
        NBAuroraInkMap.shared.update(lease, active: active,
                                    reduceMotion: reduceMotion)
    }
}

/// Observe only this scope's paint. The map never publishes to inactive paint,
/// even if List retains the row after it has scrolled out of view.
@available(iOS 17.0, tvOS 17.0, *)
struct NBAuroraMappedForeground<Content: View>: View {
    let content: Content
    let primary: NBThemeColor
    let secondary: NBThemeColor?
    let adaptsPrimary: Bool
    let adaptsSecondary: Bool
    let bounds: CGRect
    let identity: NBAuroraShaderIdentity
    @ObservedObject var paint: NBAuroraInkPaint

    var body: some View {
        let field = paint.frame.flatMap { $0.identity == identity ? $0 : nil }
        if let secondary {
            content.foregroundStyle(ink(primary, adapts: adaptsPrimary, field: field),
                                    ink(secondary, adapts: adaptsSecondary, field: field))
        } else {
            content.foregroundStyle(ink(primary, adapts: adaptsPrimary, field: field))
        }
    }

    private func ink(_ fallback: NBThemeColor, adapts: Bool,
                     field: NBAuroraInkMap.Frame?) -> AnyShapeStyle {
        guard adapts && fallback.alpha > 0 else { return AnyShapeStyle(fallback.color) }
        let fill: AnyShapeStyle
        if let field {
            fill = AnyShapeStyle(
                ShaderLibrary.bundle(.module).auroraTextInk(
                    .float4(Float(bounds.minX), Float(bounds.minY),
                            Float(bounds.width), Float(bounds.height)),
                    .float2(Float(NBAuroraInkMapFormat.width), Float(NBAuroraInkMapFormat.height)),
                    field.argument, .float(Float(fallback.alpha)))
                    .in(bounds)
            )
        } else {
            // Keep glyphs visible during initial setup, a shuffle, or a Metal
            // failure. Never hide controls while waiting for the first map.
            fill = AnyShapeStyle(Color.white.opacity(fallback.alpha).blendMode(.difference))
        }
        return AnyShapeStyle(
            fill.shadow(.drop(color: .black.opacity(0.95), radius: 0.65))
                .shadow(.drop(color: .black.opacity(0.8), radius: 1.2, y: 0.5))
        )
    }
}

extension NBThemeRole {
    /// Status colors and text on filled buttons retain their semantic colors.
    var usesAuroraText: Bool {
        switch self {
        case .text, .textSecondary, .textTertiary, .disabledText, .title, .heading,
             .accent, .navigationTitle, .navigationText, .navigationTint,
             .barButtonTint, .tabSelected, .tabUnselected,
             .searchText, .searchPlaceholder, .searchTint:
            return true
        default:
            return false
        }
    }
}

#if DEBUG
private struct NBAuroraTextPreview: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("Colors within each letter")
                .font(.system(size: 42, weight: .bold))
                .nbThemeForeground(.text)
                .padding()
                .background {
                    NBThemeSurface(NBThemeColor(red: 0, green: 0, blue: 0),
                                   in: RoundedRectangle(cornerRadius: 18))
                }

            Text("Small captions follow the same moving background.")
                .font(.caption)
                .nbThemeForeground(.textSecondary)

            HStack(spacing: 0) {
                forBackdrop(.black)
                forBackdrop(Color(white: 0.5))
                forBackdrop(.white)
            }

            Label("Status colors keep their meaning", systemImage: "exclamationmark.triangle")
                .nbThemeForeground(.warning)

            Button("Shuffle Aurora") { NBAurora.randomize() }
                .nbThemeForeground(.accent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            NBThemeBackdrop(base: NBThemeColor(red: 0, green: 0, blue: 0))
                .ignoresSafeArea()
        }
    }

    private func forBackdrop(_ color: Color) -> some View {
        VStack(spacing: 8) {
            Text("Aa")
                .font(.system(size: 36, weight: .bold))
                .nbThemeForeground(.text)
            Text("Small caption")
                .font(.caption)
                .nbThemeForeground(.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(color)
    }
}

private struct NBAuroraTextStylePreviews: PreviewProvider {
    static var previews: some View {
        NBAuroraTextPreview()
            .preferredColorScheme(.dark)
            .previewDisplayName("Bright adaptive text — Dark")
        NBAuroraTextPreview()
            .preferredColorScheme(.light)
            .previewDisplayName("Bright adaptive text — Light")
    }
}
#endif

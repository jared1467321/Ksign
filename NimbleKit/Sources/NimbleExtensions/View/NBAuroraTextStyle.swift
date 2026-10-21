import SwiftUI

/// Adapt only foreground paint. Shader fills keep the complementary hue vivid
/// while controlling brightness independently of the aurora's exposure.
struct NBAuroraTextStyleModifier: ViewModifier {
    @AppStorage("Feather.auroraBackground") private var aurora = true
    @AppStorage("Feather.auroraAdaptiveText") private var adaptiveText = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

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
            NBAuroraTextShaderScope(
                content: content, primary: primary, secondary: secondary,
                adaptsPrimary: adaptsPrimary, adaptsSecondary: adaptsSecondary
            )
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
    @StateObject private var lease = NBAuroraInkLease()
    @State private var frame = CGRect.zero
    @State private var viewport: AuroraViewport?
    @State private var viewportFrame = CGRect.zero
    @State private var isVisible = false

    let content: Content
    let primary: NBThemeColor
    let secondary: NBThemeColor?
    let adaptsPrimary: Bool
    let adaptsSecondary: Bool

    var body: some View {
        let size = viewport?.size ?? CGSize(width: max(1, frame.width), height: max(1, frame.height))
        // SwiftUI's global origin can be presentation-local. Reconcile it with
        // the UIKit window, while following scroll offsets between reports.
        let origin = viewport.map {
            CGPoint(x: $0.origin.x + frame.minX - viewportFrame.minX,
                    y: $0.origin.y + frame.minY - viewportFrame.minY)
        } ?? frame.origin
        let bounds = CGRect(x: -origin.x, y: -origin.y, width: size.width, height: size.height)

        NBAuroraMappedForeground(content: content, primary: primary, secondary: secondary,
                                 adaptsPrimary: adaptsPrimary, adaptsSecondary: adaptsSecondary,
                                 bounds: bounds, identity: session.identity.shaderIdentity,
                                 reduceMotion: reduceMotion)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .background {
                AuroraViewportReader {
                    viewport = $0
                    viewportFrame = frame
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onAppear { isVisible = true; updateLease() }
            .onDisappear { isVisible = false; updateLease() }
            .onChange(of: scenePhase) { _ in updateLease() }
            .onChange(of: reduceMotion) { _ in updateLease() }
            .onChange(of: session.identity.shaderIdentity) { _ in updateLease() }
    }

    private func updateLease() {
        NBAuroraInkMap.shared.update(lease, active: isVisible && scenePhase == .active,
                                    reduceMotion: reduceMotion)
    }
}

/// Only this small paint wrapper observes map frames. Map updates do not poll
/// geometry, create per-label clocks, or rebuild the enclosing screen's content.
@available(iOS 17.0, tvOS 17.0, *)
private struct NBAuroraMappedForeground<Content: View>: View {
    @ObservedObject private var map = NBAuroraInkMap.shared
    let content: Content
    let primary: NBThemeColor
    let secondary: NBThemeColor?
    let adaptsPrimary: Bool
    let adaptsSecondary: Bool
    let bounds: CGRect
    let identity: NBAuroraShaderIdentity
    let reduceMotion: Bool

    var body: some View {
        let field = map.frame(for: identity, reduceMotion: reduceMotion)
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

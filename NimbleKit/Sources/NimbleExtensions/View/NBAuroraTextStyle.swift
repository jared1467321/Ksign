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
        // Reuse the backdrop's identity, noise and elapsed-time calculation.
        // Prepare layout/identity arguments outside the animation callback.
        let identity = Shader.Argument.floatArray(session.identity.shaderIdentity.values)
        let noise = Shader.Argument.image(AuroraNoiseCache.image)
        let size = viewport?.size ?? CGSize(width: max(1, frame.width), height: max(1, frame.height))
        // SwiftUI's global origin can be presentation-local. Reconcile it with
        // the UIKit window, while following scroll offsets between reports.
        let origin = viewport.map {
            CGPoint(x: $0.origin.x + frame.minX - viewportFrame.minX,
                    y: $0.origin.y + frame.minY - viewportFrame.minY)
        } ?? frame.origin
        let windowBounds = CGRect(x: -origin.x, y: -origin.y,
                                  width: size.width, height: size.height)
        let shader = ShaderLibrary.bundle(.module).auroraTextInk

        TimelineView(.animation(minimumInterval: 1.0 / 30,
                                paused: !isVisible || reduceMotion || scenePhase != .active)) { timeline in
            let time = Shader.Argument.float(Float(session.time(at: timeline.date, reduceMotion: reduceMotion)))
            let primaryInk = ink(primary, adapts: adaptsPrimary, shader: shader,
                                 time: time, identity: identity, noise: noise,
                                 bounds: windowBounds)
            if let secondary {
                content.foregroundStyle(primaryInk,
                    ink(secondary, adapts: adaptsSecondary, shader: shader,
                        time: time, identity: identity, noise: noise,
                        bounds: windowBounds))
            } else {
                content.foregroundStyle(primaryInk)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .background {
            AuroraViewportReader {
                viewport = $0
                viewportFrame = frame
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    private func ink(_ fallback: NBThemeColor, adapts: Bool, shader: ShaderFunction,
                     time: Shader.Argument,
                     identity: Shader.Argument, noise: Shader.Argument,
                     bounds: CGRect) -> AnyShapeStyle {
        guard adapts && fallback.alpha > 0 else { return AnyShapeStyle(fallback.color) }
        return AnyShapeStyle(
            shader(.float4(Float(bounds.minX), Float(bounds.minY),
                           Float(bounds.width), Float(bounds.height)),
                   time, identity, noise, .float(Float(fallback.alpha)))
                // Anchor the field to the window, including inherited row and
                // canvas foregrounds, rather than restarting it in each word.
                .in(bounds)
                .shadow(.drop(color: .black.opacity(0.95), radius: 0.65))
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

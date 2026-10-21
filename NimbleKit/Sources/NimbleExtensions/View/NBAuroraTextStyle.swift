import SwiftUI

/// Blending the glyph paint (rather than its containing view) keeps images,
/// glass, and control fills out of the effect. Mint in difference mode produces
/// colorful ink from the actual composited backing at every glyph pixel, with
/// luminous tones over dark backings and deeper jewel tones over bright ones.
/// The compositor follows the sky without another animation clock, geometry
/// observer, screen capture, or copy of the aurora shader.
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
        if let secondary {
            content.foregroundStyle(ink(primary, adapts: adaptsPrimary),
                                    ink(secondary, adapts: adaptsSecondary))
        } else {
            content.foregroundStyle(ink(primary, adapts: adaptsPrimary))
        }
    }

    private func ink(_ fallback: NBThemeColor, adapts: Bool) -> AnyShapeStyle {
        guard enabled && adapts && fallback.alpha > 0 else {
            return AnyShapeStyle(fallback.color)
        }

        // Difference blending alone loses contrast against some backing colors.
        // Opposing fine light/dark contours preserve glyph edges there.
        // Keep shadows on the paint, so inherited row/canvas styles never cast
        // a shadow around an entire card or an app icon.
        return AnyShapeStyle(
            // Unequal channels keep neutral backings colorful: mint on black,
            // emerald on middle gray, and deep ruby on white.
            Color(.sRGB, red: 0.42, green: 1.0, blue: 0.72, opacity: fallback.alpha)
                .blendMode(.difference)
                .shadow(.drop(color: .black.opacity(0.9), radius: 0.75, y: 0.5))
                .shadow(.drop(color: .white.opacity(0.7), radius: 0.35, y: -0.5))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let travel = sin(timeline.date.timeIntervalSinceReferenceDate * 0.4) * 0.5
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
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                LinearGradient(colors: [.cyan, .blue, .purple, .red, .yellow, .green, .cyan],
                               startPoint: UnitPoint(x: -0.5 + travel, y: 0),
                               endPoint: UnitPoint(x: 1.5 + travel, y: 1))
                    .ignoresSafeArea()
            }
        }
    }

    private func forBackdrop(_ color: Color) -> some View {
        Text("Aa")
            .font(.system(size: 36, weight: .bold))
            .nbThemeForeground(.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(color)
    }
}

private struct NBAuroraTextStylePreviews: PreviewProvider {
    static var previews: some View {
        NBAuroraTextPreview()
            .preferredColorScheme(.dark)
            .previewDisplayName("Complementary text — Dark")
        NBAuroraTextPreview()
            .preferredColorScheme(.light)
            .previewDisplayName("Complementary text — Light")
    }
}
#endif

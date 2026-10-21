import SwiftUI

/// Blending the glyph paint (rather than its containing view) keeps images,
/// glass, and control fills out of the effect. A pale blue hard-light source
/// produces luminous pastels from the composited backing at every glyph pixel.
/// Dark contours separate the bright ink from even the brightest aurora areas.
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

        // Hard light with every source channel above 0.5 keeps the ink bright:
        // each output channel is 1 - 2 * (1 - backing) * (1 - source).
        // Opaque ink has a floor of (0.52, 0.72, 0.92), while the backing
        // shifts the ink through blue, pink, aqua and near-white. A tight dark
        // contour supplies contrast when the backing itself approaches white.
        // Keep shadows on the paint, so inherited row/canvas styles never cast
        // a shadow around an entire card or an app icon.
        return AnyShapeStyle(
            Color(.sRGB, red: 0.76, green: 0.86, blue: 0.96, opacity: fallback.alpha)
                .blendMode(.hardLight)
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

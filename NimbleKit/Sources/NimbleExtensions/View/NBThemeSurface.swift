import SwiftUI

/// A tinted, glossy surface shared by cards, badges and controls. The color
/// remains the editable theme value; the finish never changes the profile.
public struct NBThemeSurface<S: Shape>: View {
    @AppStorage("Feather.glossySurfaces") private var glossySurfaces = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private let color: NBThemeColor
    private let shape: S
    private let supportsGloss: Bool

    public init(_ color: NBThemeColor, in shape: S, supportsGloss: Bool = true) {
        self.color = color
        self.shape = shape
        self.supportsGloss = supportsGloss
    }

    public var body: some View {
        Group {
            if glossySurfaces && supportsGloss && !reduceTransparency && contrast != .increased {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue).opacity(0.82))
                    shape.fill(LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.16), location: 0),
                            .init(color: .white.opacity(0.04), location: 0.42),
                            .init(color: .clear, location: 0.55),
                            .init(color: .white.opacity(0.035), location: 1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    shape.stroke(LinearGradient(
                        colors: [.white.opacity(0.28), .white.opacity(0.035), .white.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ), lineWidth: 0.75)
                }
                .clipShape(shape)
                .opacity(color.alpha)
            } else {
                shape.fill(color.color)
            }
        }
    }
}

extension NBThemeRole {
    /// Page backgrounds, masks, scrims, separators and text must retain their
    /// original paint behavior, even when the surrounding surfaces are glassy.
    var supportsGlossySurface: Bool {
        switch self {
        case .elevated, .elevatedHigh, .controlFill, .controlFillStrong,
             .overlaySurface, .accent, .secondaryAccent, .tertiaryAccent,
             .selection, .headingFill, .success, .warning, .danger, .expired,
             .searchBackground, .segmentBackground, .segmentSelectedBackground:
            return true
        default:
            return false
        }
    }
}

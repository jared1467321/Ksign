import SwiftUI

/// Clear glass ported from Tally's isolated glass layer. Reflections and rims
/// affect only the backing surface; foreground text stays sharp and opaque.
public struct NBThemeSurface<S: Shape>: View {
    @AppStorage("Feather.glossySurfaces") private var glossySurfaces = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    @State private var paneID = UUID()

    private let color: NBThemeColor
    private let shape: S
    private let supportsGloss: Bool
    private let tintStrength: Double

    public init(_ color: NBThemeColor, in shape: S, supportsGloss: Bool = true, tintStrength: Double = 0.10) {
        self.color = color
        self.shape = shape
        self.supportsGloss = supportsGloss
        self.tintStrength = tintStrength
    }

    private var enabled: Bool {
        glossySurfaces && supportsGloss && !reduceTransparency && contrast != .increased
    }

    public var body: some View {
        Group {
            if enabled {
                ZStack {
                    nativeGlass
                    shape.fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue).opacity(tintStrength))
                    shape.fill(LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.105), location: 0),
                            .init(color: .white.opacity(0.032), location: 0.22),
                            .init(color: .clear, location: 0.52)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    shape.fill(RadialGradient(colors: [.white.opacity(0.165), .white.opacity(0.04), .clear],
                                              center: .topLeading, startRadius: 0, endRadius: 245))
                    shape.fill(LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.015), location: 0.34),
                            .init(color: .white.opacity(0.145), location: 0.47),
                            .init(color: .white.opacity(0.04), location: 0.54),
                            .init(color: .clear, location: 0.67)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    shape.stroke(LinearGradient(
                        colors: [.white.opacity(0.44), .white.opacity(0.08), .white.opacity(0.21)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 1.15)
                    shape.stroke(LinearGradient(
                        colors: [.white.opacity(0.205), .clear, .white.opacity(0.07)],
                        startPoint: .top, endPoint: .bottomTrailing
                    ), lineWidth: 0.65)
                    .padding(1.5)
                }
                .clipShape(shape)
                .opacity(color.alpha)
                .background {
                    GeometryReader { proxy in
                        let rect = proxy.frame(in: .global)
                        Color.clear.preference(key: NBGlassPanePreferenceKey.self,
                                               value: rect.width > 140 && rect.height > 64
                                               ? [paneID: NBGlassPaneFrame(rect: rect)] : [:])
                    }
                }
            } else {
                shape.fill(color.color)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var nativeGlass: some View {
        if #available(iOS 26.0, tvOS 26.0, *) {
            shape.fill(.white.opacity(0.004))
                .glassEffect(.clear, in: shape)
                .mask {
                    ZStack {
                        shape.fill(.white.opacity(0.28))
                        shape.stroke(.white, lineWidth: 20)
                        shape.stroke(.white.opacity(0.92), lineWidth: 48)
                            .blur(radius: 4.5)
                    }
                    .compositingGroup()
                    .clipShape(shape)
                }
        } else {
            shape.fill(.ultraThinMaterial)
                .opacity(scheme == .dark ? 0.48 : 0.65)
        }
    }
}

extension NBThemeRole {
    var glassTintStrength: Double {
        switch self {
        case .accent, .secondaryAccent, .tertiaryAccent, .success, .warning,
             .danger, .expired, .selection, .segmentSelectedBackground:
            return 0.82
        default:
            return 0.10
        }
    }

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

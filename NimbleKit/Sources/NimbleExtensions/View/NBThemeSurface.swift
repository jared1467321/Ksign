import SwiftUI

public enum NBThemeSurfaceFinish {
    case standard
    case navigation
    case sheet
}

/// Clear glass ported from Tally's isolated glass layer. Reflections and rims
/// affect only the backing surface; foreground text stays sharp and opaque.
public struct NBThemeSurface<S: Shape>: View {
    @AppStorage("Feather.glossySurfaces") private var glossySurfaces = true
    @AppStorage("Feather.auroraBackground") private var auroraBackground = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    @State private var paneID = UUID()

    private let color: NBThemeColor
    private let shape: S
    private let supportsGloss: Bool
    private let tintStrength: Double
    private let finish: NBThemeSurfaceFinish

    public init(_ color: NBThemeColor, in shape: S, supportsGloss: Bool = true,
                tintStrength: Double = 0.10, finish: NBThemeSurfaceFinish = .standard) {
        self.color = color
        self.shape = shape
        self.supportsGloss = supportsGloss
        self.tintStrength = tintStrength
        self.finish = finish
    }

    private var enabled: Bool {
        glossySurfaces && supportsGloss && !reduceTransparency && contrast != .increased
    }

    private var shine: Double {
        finish == .sheet ? 0.10 : finish == .navigation ? 0.45 : 1
    }
    private var rimShine: Double {
        finish == .sheet ? 0.35 : 1
    }
    private var surfaceTint: Double {
        auroraBackground && tintStrength <= 0.10 ? min(tintStrength, 0.025) : tintStrength
    }
    private var optics: (center: Double, rim: Double, rimWidth: CGFloat,
                         transition: Double, transitionWidth: CGFloat, blur: CGFloat) {
        switch finish {
        case .standard: return (0.28, 1, 20, 0.92, 48, 4.5)
        case .navigation: return (0.12, 0.35, 8, 0.20, 16, 2)
        case .sheet: return (0.025, 0.25, 2, 0.10, 8, 2)
        }
    }

    public var body: some View {
        Group {
            if enabled {
                ZStack {
                    nativeGlass
                        // Keep the same clear optical finish in both aurora
                        // appearances. Only the backing material receives this
                        // environment; foreground labels retain their theme.
                        .environment(\.colorScheme, auroraBackground ? .dark : scheme)
                    shape.fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue).opacity(surfaceTint))
                    shape.fill(LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.105 * shine), location: 0),
                            .init(color: .white.opacity(0.032 * shine), location: 0.22),
                            .init(color: .clear, location: 0.52)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    shape.fill(RadialGradient(colors: [.white.opacity(0.165 * shine), .white.opacity(0.04 * shine), .clear],
                                              center: .topLeading, startRadius: 0, endRadius: 245))
                    shape.fill(LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.015 * shine), location: 0.34),
                            .init(color: .white.opacity(0.145 * shine), location: 0.47),
                            .init(color: .white.opacity(0.04 * shine), location: 0.54),
                            .init(color: .clear, location: 0.67)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    shape.stroke(LinearGradient(
                        colors: [.white.opacity(0.44 * rimShine), .white.opacity(0.08 * rimShine), .white.opacity(0.21 * rimShine)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 1.15)
                    shape.stroke(LinearGradient(
                        colors: [.white.opacity(0.205 * rimShine), .clear, .white.opacity(0.07 * rimShine)],
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
                        shape.fill(.white.opacity(optics.center))
                        shape.stroke(.white.opacity(optics.rim), lineWidth: optics.rimWidth)
                        shape.stroke(.white.opacity(optics.transition), lineWidth: optics.transitionWidth)
                            .blur(radius: optics.blur)
                    }
                    .compositingGroup()
                    .clipShape(shape)
                }
        } else {
            shape.fill(.ultraThinMaterial)
                .opacity(finish == .sheet ? 0.12 : auroraBackground || scheme == .dark ? 0.48 : 0.35)
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

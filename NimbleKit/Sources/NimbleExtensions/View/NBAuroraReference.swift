import SwiftUI
import UIKit

/// One identity and animation clock for all screens, including presentations.
@MainActor
private final class AuroraSession: ObservableObject {
    static let shared = AuroraSession()
    @Published var identity = AuroraIdentityGenerator.next()
    @Published var accumulatedTime: TimeInterval = 0
    @Published var activeStart: Date? = Date()

    func setActive(_ active: Bool) {
        if active, activeStart == nil {
            activeStart = Date()
        } else if !active, let start = activeStart {
            accumulatedTime += max(0, Date().timeIntervalSince(start))
            activeStart = nil
        }
    }

    func randomize() {
        identity = AuroraIdentityGenerator.next()
        accumulatedTime = 0
        if activeStart != nil { activeStart = Date() }
    }
}

@MainActor
public enum NBAurora {
    public static func randomize() { AuroraSession.shared.randomize() }
    public static func setActive(_ active: Bool) { AuroraSession.shared.setActive(active) }
}

struct NBGlassPaneFrame: Equatable, Sendable {
    let rect: CGRect
}

struct NBGlassPanePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: NBGlassPaneFrame] = [:]
    static func reduce(value: inout [UUID: NBGlassPaneFrame], nextValue: () -> [UUID: NBGlassPaneFrame]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct AuroraViewport: Equatable {
    let size: CGSize
    let origin: CGPoint
}

/// Read-only geometry: each hosting container paints its own sky, but samples
/// the same window coordinates so nested lists and headers join continuously.
private struct AuroraViewportReader: UIViewRepresentable {
    let onChange: (AuroraViewport) -> Void

    func makeUIView(context: Context) -> AuroraViewportView {
        AuroraViewportView(frame: .zero)
    }

    func updateUIView(_ view: AuroraViewportView, context: Context) {
        view.onChange = onChange
        view.scheduleReport()
    }
}

private final class AuroraViewportView: UIView {
    var onChange: ((AuroraViewport) -> Void)?
    private var pending = false
    private var lastReported: AuroraViewport?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleReport()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleReport()
    }

    func scheduleReport() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            guard let window = self.window, self.bounds.width > 0, self.bounds.height > 0 else { return }
            let viewport = AuroraViewport(size: window.bounds.size,
                                          origin: self.convert(self.bounds.origin, to: window))
            guard viewport != self.lastReported else { return }
            self.lastReported = viewport
            self.onChange?(viewport)
        }
    }
}

/// Render the sky separately from foreground content so optics never bend text.
struct NBThemeBackdrop: View {
    @AppStorage("Feather.auroraBackground") private var auroraBackground = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @StateObject private var session = AuroraSession.shared
    @StateObject private var performance = AuroraPerformanceController()
    @State private var viewport: AuroraViewport?

    let base: NBThemeColor
    var panes: [CGRect] = []

    private var enabled: Bool { auroraBackground && !reduceTransparency && contrast != .increased }
    private var animating: Bool { enabled && !reduceMotion && scenePhase == .active }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if enabled {
                    if #available(iOS 17.0, tvOS 17.0, *) {
                        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animating)) { timeline in
                            let elapsed = reduceMotion ? 1.8 : session.accumulatedTime
                                + (session.activeStart.map { max(0, timeline.date.timeIntervalSince($0)) } ?? 0)
                            sky(size: proxy.size, origin: proxy.frame(in: .global).origin, time: elapsed)
                        }
                    } else {
                        // The app retains iOS 16 support; native shader effects
                        // start in iOS 17 and Liquid Glass starts in iOS 26.
                        LinearGradient(colors: scheme == .dark
                                       ? [Color(red: 0.13, green: 0.06, blue: 0.20), .black, Color(red: 0.05, green: 0.24, blue: 0.18)]
                                       : [Color(red: 0.69, green: 0.44, blue: 0.98), Color(red: 0.98, green: 0.72, blue: 0.38), Color(red: 0.38, green: 0.91, blue: 0.69)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                } else {
                    base.color
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(AuroraViewportReader { viewport = $0 })
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .onAppear { updateMonitoring() }
        .onDisappear { performance.stop() }
        .onChange(of: animating) { _ in updateMonitoring() }
    }

    private func updateMonitoring() {
        if #available(iOS 17.0, tvOS 17.0, *), animating {
            performance.start()
        } else {
            performance.stop()
        }
    }

    @available(iOS 17.0, tvOS 17.0, *)
    private func sky(size: CGSize, origin: CGPoint, time: TimeInterval) -> some View {
        let scale = performance.renderScale
        let scene = viewport ?? AuroraViewport(size: size, origin: .zero)
        let renderSize = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let words = session.identity.shaderWords
        let rects = panes.prefix(2).map {
            CGRect(x: ($0.minX - origin.x) * scale, y: ($0.minY - origin.y) * scale,
                   width: $0.width * scale, height: $0.height * scale)
        }
        let first = rects.first ?? .zero
        let second = rects.dropFirst().first ?? .zero
        return ZStack {
            Rectangle()
                .fill(Color.black)
                .frame(width: renderSize.width, height: renderSize.height)
                .colorEffect(ShaderLibrary.bundle(.module).auroraBorealis(
                    .float2(Float(max(1, scene.size.width * scale)), Float(max(1, scene.size.height * scale))),
                    .float(Float(time)),
                    .float4(words[0], words[1], words[2], words[3]),
                    .float4(words[4], words[5], words[6], words[7]),
                    .float(1.34), .image(AuroraNoiseCache.image),
                    .float(scheme == .light ? 1 : 0),
                    .float2(Float(scene.origin.x * scale), Float(scene.origin.y * scale))
                ))
                .layerEffect(ShaderLibrary.bundle(.module).auroraPaneOptics(
                    .float2(Float(first.minX), Float(first.minY)),
                    .float2(Float(first.width), Float(first.height)), .float(Float(18 * scale)),
                    .float2(Float(second.minX), Float(second.minY)),
                    .float2(Float(second.width), Float(second.height)), .float(Float(18 * scale)),
                    .float(Float(scale))
                ), maxSampleOffset: CGSize(width: 32 * scale, height: 32 * scale))
                .scaleEffect(1 / scale, anchor: .topLeading)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()

            ZStack {
                Starfield(time: time, seed: session.identity.starfieldSeed(stream: 0xA11CE5EED),
                          count: 54, tint: Color(red: 1, green: 0.824, blue: 0.451),
                          speedScale: 0.74, sizeScale: 0.82)
                    .opacity(scheme == .dark ? 0.43 : 0.35)
                Starfield(time: time, seed: session.identity.starfieldSeed(stream: 0x57EE1F1E1D),
                          count: 26, tint: Color(red: 0.627, green: 0.784, blue: 0.980),
                          speedScale: 0.40, sizeScale: 0.94)
                    .opacity(scheme == .dark ? 0.20 : 0.18)
            }
            .frame(width: scene.size.width, height: scene.size.height)
            .offset(x: -scene.origin.x, y: -scene.origin.y)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
        }
    }
}

private struct AuroraIdentity: Equatable, Sendable {
    let high: UInt64
    let low: UInt64

    // SwiftUI's shader API exposes float vectors rather than integer vectors.
    // Splitting each UInt64 into exact UInt16-sized Float values carries all 128
    // identity bits into Metal without losing low bits to Float precision.
    var shaderWords: [Float] {
        [
            Float(low & 0xFFFF),
            Float((low >> 16) & 0xFFFF),
            Float((low >> 32) & 0xFFFF),
            Float((low >> 48) & 0xFFFF),
            Float(high & 0xFFFF),
            Float((high >> 16) & 0xFFFF),
            Float((high >> 32) & 0xFFFF),
            Float((high >> 48) & 0xFFFF)
        ]
    }

    func starfieldSeed(stream: UInt64) -> UInt64 {
        auroraMix64(low ^ high.rotatedLeft(by: 23) ^ stream)
    }
}

private extension UInt64 {
    func rotatedLeft(by amount: UInt64) -> UInt64 {
        let shift = amount & 63
        guard shift != 0 else { return self }
        return (self << shift) | (self >> (64 - shift))
    }
}

// SplitMix64's final permutation is composed only of reversible operations
// (xor-shifts, addition, and multiplication by odd constants), making it useful
// here as both a high-quality mixer and a one-to-one mapping of the counter.
private func auroraMix64(_ value: UInt64) -> UInt64 {
    var z = value &+ 0x9E3779B97F4A7C15
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
    return z ^ (z >> 31)
}

private enum AuroraIdentityGenerator {
    private static let installationHighKey = "Ksign.aurora.installationHigh"
    private static let installationLowKey = "Ksign.aurora.installationLow"
    private static let generationCounterKey = "Ksign.aurora.generationCounter"

    static func next() -> AuroraIdentity {
        let defaults = UserDefaults.standard
        let installationHigh = persistentWord(
            defaults: defaults,
            key: installationHighKey
        )
        let installationLow = persistentWord(
            defaults: defaults,
            key: installationLowKey
        )
        let counter = UInt64(defaults.string(forKey: generationCounterKey) ?? "") ?? 0

        defaults.set(String(counter &+ 1), forKey: generationCounterKey)

        // The high half identifies this installation; the low half is a
        // one-to-one permutation of its generation number. Keeping the counter
        // in the identity rather than merely drawing another random value gives
        // us a practical no-repeat guarantee within this installation.
        return AuroraIdentity(
            high: auroraMix64(installationHigh),
            low: auroraMix64(counter ^ installationLow)
        )
    }

    private static func persistentWord(defaults: UserDefaults, key: String) -> UInt64 {
        if let stored = defaults.string(forKey: key), let value = UInt64(stored) {
            return value
        }

        let value = UInt64.random(in: UInt64.min...UInt64.max)
        defaults.set(String(value), forKey: key)
        return value
    }
}


@MainActor
private enum AuroraNoiseCache {
    static let image: Image = {
        let dimension = 256
        var bytes = [UInt8](repeating: 0, count: dimension * dimension)

        // Pre-bake the same lattice hash used by the original shader. This
        // preserves the established noise character while moving that repeated
        // work off the per-frame GPU path.
        @inline(__always)
        func fract(_ value: Float) -> Float {
            value - value.rounded(.down)
        }

        for y in 0..<dimension {
            for x in 0..<dimension {
                var px = fract(Float(x) * 123.34)
                var py = fract(Float(y) * 456.21)
                let dotValue = px * (px + 45.32) + py * (py + 45.32)
                px += dotValue
                py += dotValue
                let value = min(max(fract(px * py), 0), 1)
                bytes[y * dimension + x] = UInt8((value * 255).rounded())
            }
        }

        let data = Data(bytes) as CFData
        let provider = CGDataProvider(data: data)!
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        let cgImage = CGImage(
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: dimension,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!

        return Image(decorative: cgImage, scale: 1, orientation: .up)
    }()
}


@MainActor
private final class AuroraPerformanceController: NSObject, ObservableObject {
    @Published private(set) var renderScale: CGFloat = 0.50

    private let qualitySteps: [CGFloat] = [0.38, 0.42, 0.46, 0.50, 0.54]
    private var qualityIndex = 3
    private var displayLink: CADisplayLink?
    private var sampleStart: CFTimeInterval?
    private var deliveredFrames = 0
    private var stableWindows = 0

    func start() {
        guard displayLink == nil else { return }

        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 24,
                maximum: 30,
                preferred: 30
            )
        } else {
            link.preferredFramesPerSecond = 30
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
        resetSampling()
        applySystemPressureCap()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        resetSampling()
    }

    @objc
    private func displayLinkFired(_ link: CADisplayLink) {
        guard let start = sampleStart else {
            sampleStart = link.timestamp
            deliveredFrames = 0
            return
        }

        deliveredFrames += 1
        let elapsed = link.timestamp - start
        guard elapsed >= 1.5 else { return }

        let deliveredFPS = Double(deliveredFrames) / elapsed
        let processInfo = ProcessInfo.processInfo

        if processInfo.thermalState == .serious || processInfo.thermalState == .critical {
            lowerQuality(toAtMost: 1)
            stableWindows = 0
        } else if deliveredFPS < 26.5 {
            lowerQuality()
            stableWindows = 0
        } else if processInfo.isLowPowerModeEnabled {
            // Low Power Mode receives a modest cap, but only after the current
            // sample window so activating it cannot interrupt a visible frame.
            lowerQuality(toAtMost: 2)
            stableWindows = 0
        } else if deliveredFPS >= 29.2 {
            stableWindows += 1
            if stableWindows >= 4 {
                raiseQuality()
                stableWindows = 0
            }
        } else {
            stableWindows = 0
        }

        sampleStart = link.timestamp
        deliveredFrames = 0
    }

    private func applySystemPressureCap() {
        let processInfo = ProcessInfo.processInfo
        if processInfo.thermalState == .serious || processInfo.thermalState == .critical {
            lowerQuality(toAtMost: 1)
        } else if processInfo.isLowPowerModeEnabled {
            lowerQuality(toAtMost: 2)
        }
    }

    private func lowerQuality(toAtMost maximumIndex: Int? = nil) {
        let nextIndex: Int
        if let maximumIndex {
            nextIndex = min(qualityIndex, maximumIndex)
        } else {
            nextIndex = max(qualityIndex - 1, 0)
        }
        setQualityIndex(nextIndex)
    }

    private func raiseQuality() {
        setQualityIndex(min(qualityIndex + 1, qualitySteps.count - 1))
    }

    private func setQualityIndex(_ newIndex: Int) {
        guard newIndex != qualityIndex else { return }
        qualityIndex = newIndex
        renderScale = qualitySteps[newIndex]
    }

    private func resetSampling() {
        sampleStart = nil
        deliveredFrames = 0
        stableWindows = 0
    }

}


private struct Starfield: View {
    private struct Generator {
        var state: UInt64

        mutating func unit() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31

            // Use the upper 53 bits so every generated Double maps cleanly to
            // the mantissa without introducing modulo bias.
            return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }

        mutating func value(in range: ClosedRange<Double>) -> Double {
            range.lowerBound + unit() * (range.upperBound - range.lowerBound)
        }
    }

    private struct Mote {
        let startX: CGFloat
        let startY: CGFloat
        let velocityX: Double
        let velocityY: Double
        let sway: CGFloat
        let swayRate: Double
        let radius: CGFloat
        let phase: Double
        let twinkleRate: Double
        let peak: Double
    }

    private let motes: [Mote]
    private let time: TimeInterval
    private let tint: Color
    private let speedScale: Double
    private let sizeScale: CGFloat

    init(
        time: TimeInterval,
        seed: UInt64,
        count: Int = 34,
        tint: Color = .white,
        speedScale: Double = 1.0,
        sizeScale: CGFloat = 1.0
    ) {
        self.time = time
        self.tint = tint
        self.speedScale = speedScale
        self.sizeScale = sizeScale

        var generator = Generator(state: seed)
        self.motes = (0..<count).map { _ in
            Mote(
                startX: CGFloat(generator.value(in: 0...1)),
                startY: CGFloat(generator.value(in: 0...1)),
                velocityX: generator.value(in: -0.012...0.012),
                velocityY: generator.value(in: -0.009...0.017),
                sway: CGFloat(generator.value(in: 0.003...0.022)),
                swayRate: generator.value(in: 0.18...0.82),
                radius: CGFloat(generator.value(in: 0.68...2.20)),
                phase: generator.value(in: 0...(2 * .pi)),
                twinkleRate: generator.value(in: 0.42...2.10),
                peak: generator.value(in: 0.25...0.90)
            )
        }
    }

    var body: some View {
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            let elapsed = time * speedScale

            for mote in motes {
                let xProgress = Double(mote.startX)
                    + elapsed * mote.velocityX
                    + Double(mote.sway) * sin(elapsed * mote.swayRate + mote.phase)
                let yProgress = Double(mote.startY)
                    + elapsed * mote.velocityY
                    + Double(mote.sway * 0.45)
                        * cos(elapsed * (mote.swayRate * 0.73) + mote.phase)
                let x = wrapped(xProgress) * size.width
                let y = wrapped(yProgress) * size.height

                let twinkle = (sin(elapsed * mote.twinkleRate + mote.phase) + 1) / 2
                let alpha = mote.peak * (0.14 + 0.86 * twinkle)
                let radius = mote.radius * sizeScale

                let haloRadius = radius * 3.4
                context.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: x - haloRadius,
                            y: y - haloRadius,
                            width: haloRadius * 2,
                            height: haloRadius * 2
                        )
                    ),
                    with: .color(tint.opacity(alpha * 0.13))
                )

                context.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: x - radius,
                            y: y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )
                    ),
                    with: .color(tint.opacity(alpha))
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func wrapped(_ value: Double) -> CGFloat {
        CGFloat(value - floor(value))
    }
}

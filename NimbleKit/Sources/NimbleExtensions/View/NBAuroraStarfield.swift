import Foundation

/// Immutable particle layout. Only positions and brightness depend on the clock.
final class NBAuroraStarfield: Sendable {
    struct Mote: Equatable, Sendable {
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

    private struct Generator {
        var state: UInt64

        mutating func unit() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }

        mutating func value(in range: ClosedRange<Double>) -> Double {
            range.lowerBound + unit() * (range.upperBound - range.lowerBound)
        }
    }

    let seed: UInt64
    let motes: [Mote]

    init(seed: UInt64, count: Int) {
        self.seed = seed
        var generator = Generator(state: seed)
        motes = (0..<count).map { _ in
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
}

struct NBAuroraStarfieldCache {
    // Keep only the current generation for each of the two starfield streams.
    // Shuffling replaces entries rather than retaining every previous sky.
    private var fields: [UInt64: NBAuroraStarfield] = [:]

    mutating func field(stream: UInt64, seed: UInt64, count: Int) -> NBAuroraStarfield {
        if let field = fields[stream], field.seed == seed, field.motes.count == count {
            return field
        }
        let field = NBAuroraStarfield(seed: seed, count: count)
        fields[stream] = field
        return field
    }
}

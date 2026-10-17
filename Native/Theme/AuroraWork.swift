import Foundation

@main
enum AuroraWorkTests {
    static func main() {
        var cache = NBAuroraStarfieldCache()
        let gold = cache.field(stream: 1, seed: 42, count: 54)
        let blue = cache.field(stream: 2, seed: 100, count: 26)

        // Rendering more frames or hosting containers must not allocate new
        // particle layouts. Each stream keeps its own layout.
        for _ in 0..<1_000 {
            assert(cache.field(stream: 1, seed: 42, count: 54) === gold)
            assert(cache.field(stream: 2, seed: 100, count: 26) === blue)
        }
        assert(gold.motes.count == 54 && blue.motes.count == 26)

        // The reference generator's first particle for seed 42. Caching must
        // preserve the existing positions, motion, size and twinkle parameters.
        let first = gold.motes[0]
        let expected: [Double] = [
            0.7415648787718233, 0.1599103928769201,
            -0.005313572873876672, -0.00005104137038542192,
            0.003722573202264678, 0.7356659689897806,
            1.0119758944425203, 5.030518444225902,
            0.9910841453805945, 0.6520133431314876
        ]
        let actual = [Double(first.startX), Double(first.startY),
                      first.velocityX, first.velocityY, Double(first.sway),
                      first.swayRate, Double(first.radius), first.phase,
                      first.twinkleRate, first.peak]
        for (value, reference) in zip(actual, expected) {
            assert(abs(value - reference) < 1e-12, "Particle appearance changed: \(value) vs \(reference)")
        }

        let shuffled = cache.field(stream: 1, seed: 43, count: 54)
        assert(shuffled !== gold && shuffled.motes != gold.motes)
        assert(cache.field(stream: 1, seed: 43, count: 54) === shuffled)
        assert(cache.field(stream: 2, seed: 100, count: 26) === blue,
               "Changing one stream must not regenerate the other")
        let resized = cache.field(stream: 1, seed: 43, count: 26)
        assert(resized !== shuffled && resized.motes == Array(shuffled.motes.prefix(26)))

        // Replacing a generation must release the cache's reference to it.
        weak var retired: NBAuroraStarfield?
        do {
            let field = cache.field(stream: 3, seed: 1, count: 1)
            retired = field
        }
        _ = cache.field(stream: 3, seed: 2, count: 1)
        assert(retired == nil, "Shuffling must not retain old particle generations")
        print("Aurora work tests passed: layout reuse, reference appearance, shuffle/count invalidation and generation release.")
    }
}

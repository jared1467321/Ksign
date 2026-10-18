import Foundation

@main
enum AuroraWorkTests {
    static func main() {
        paneSelection()
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

    static func paneSelection() {
        // Compare against the previous full sort, including equal areas and
        // equal origins. Stable ties must keep the same pane priority.
        func original(_ rects: [CGRect]) -> [CGRect] {
            Array(rects.sorted { lhs, rhs in
                let a = lhs.width * lhs.height, b = rhs.width * rhs.height
                if a != b { return a > b }
                if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
                return lhs.minX < rhs.minX
            }.prefix(2))
        }
        var rects: [CGRect] = []
        assert(NBGlassPaneSelection.largest(rects).isEmpty)
        var state: UInt64 = 42
        for count in 0..<512 {
            state = state &* 6364136223846793005 &+ 1
            let width = CGFloat((state >> 32) % 20 + 1)
            let rect = CGRect(x: CGFloat(count % 7), y: CGFloat(count % 11),
                              width: width, height: CGFloat(count % 17 + 1))
            rects.append(rect)
            assert(NBGlassPaneSelection.largest(rects.lazy.map { $0 }) == original(rects))
            let reversed = Array(rects.reversed())
            assert(NBGlassPaneSelection.largest(reversed) == original(reversed))
        }
        // Same ordering keys, different dimensions: keep the first arrival.
        let tied = [CGRect(x: 1, y: 2, width: 200, height: 100),
                    CGRect(x: 1, y: 2, width: 100, height: 200),
                    CGRect(x: 1, y: 2, width: 400, height: 50)]
        assert(NBGlassPaneSelection.largest(tied) == Array(tied.prefix(2)))
        print("Glass pane selection matches the original sort across 1,026 layouts, including stable ties.")
    }
}

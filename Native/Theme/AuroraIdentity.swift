import Foundation

/// Emit real Swift shader arguments for comparison with the original Metal
/// hash in AuroraRendering.cpp, including every packed stream and identity bit.
@main
enum AuroraIdentityTests {
    static func main() {
        print(NBAuroraShaderIdentity.streams.count)
        print(NBAuroraShaderIdentity.streams.map(String.init).joined(separator: " "))
        var state: UInt64 = 0x123456789ABCDEF0
        var identities: [(UInt64, UInt64)] = [(0, 0), (.max, .max), (0, .max), (.max, 0)]
        for bit in 0..<64 {
            identities.append((UInt64(1) << bit, 0))
            identities.append((0, UInt64(1) << bit))
        }
        for _ in 0..<256 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let high = state
            state = state &* 6364136223846793005 &+ 1442695040888963407
            identities.append((high, state))
        }
        for (high, low) in identities {
            let identity = NBAuroraShaderIdentity(high: high, low: low)
            assert(identity.values.count == 41)
            assert(identity.values.allSatisfy { $0 >= 0 && $0 < 1 })
            print("\(high) \(low) " + identity.values.map { String($0.bitPattern) }.joined(separator: " "))
        }
    }
}

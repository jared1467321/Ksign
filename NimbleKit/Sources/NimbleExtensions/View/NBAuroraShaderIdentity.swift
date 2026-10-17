import Foundation

/// The original Metal identity hash, evaluated once per sky instead of once
/// per pixel. Only exact UInt32 arithmetic and a binary Float scale move here;
/// all floating-point scene/animation calculations remain in Metal.
struct NBAuroraShaderIdentity: Equatable, Sendable {
    // Packed order shared with auroraIdentityIndex() in AuroraShaders.metal.
    static let streams: [UInt32] = [
        0x0100, 0x0101, 0x0102, 0x0103, 0x0104, 0x0105,
        0x0200,
        0x1000, 0x1001, 0x1002, 0x1003,
        0x1020, 0x1021, 0x1022, 0x1023,
        0x1040, 0x1041, 0x1042, 0x1043,
        0x1060, 0x1061, 0x1062, 0x1063,
        0x1080, 0x1081, 0x1082, 0x1083,
        0x10A0, 0x10A1, 0x10A2, 0x10A3,
        0x0300,
        0x0310, 0x0311, 0x0312,
        0x0320, 0x0321, 0x0322, 0x0323, 0x0324,
        0x0400
    ]

    let values: [Float]

    init(high: UInt64, low: UInt64) {
        let words = [UInt32(truncatingIfNeeded: low), UInt32(truncatingIfNeeded: low >> 32),
                     UInt32(truncatingIfNeeded: high), UInt32(truncatingIfNeeded: high >> 32)]
        values = Self.streams.map { stream in
            var h = Self.avalanche(0x9E3779B9 ^ (stream &* 0x85EBCA6B))
            h = Self.avalanche(h ^ words[0])
            h = Self.avalanche(h ^ words[1] ^ 0xC2B2AE35)
            h = Self.avalanche(h ^ words[2] ^ 0x27D4EB2F)
            h = Self.avalanche(h ^ words[3] ^ 0x165667B1)
            // The upper 24 bits and this power-of-two scale are exact in Float,
            // matching the old Metal result bit for bit on both platforms.
            return Float(h >> 8) * (1.0 / 16_777_216.0)
        }
    }

    private static func avalanche(_ value: UInt32) -> UInt32 {
        var value = value
        value ^= value >> 16
        value = value &* 0x7FEB352D
        value ^= value >> 15
        value = value &* 0x846CA68B
        value ^= value >> 16
        return value
    }
}

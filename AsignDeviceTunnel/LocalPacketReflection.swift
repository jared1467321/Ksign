import Foundation

enum LocalPacketReflection {
    static func reflect(_ input: Data) -> Data? {
        guard input.count >= 20 else { return nil }
        let accepted = input.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let headerLength = Int(bytes[0] & 0x0f) * 4
            let length = Int(bytes[2]) << 8 | Int(bytes[3])
            return bytes[0] >> 4 == 4 && headerLength >= 20 &&
                headerLength <= length && length == bytes.count &&
                bytes[12] == 10 && bytes[13] == 7 && bytes[14] == 0 && bytes[15] == 2 &&
                bytes[16] == 10 && bytes[17] == 7 && bytes[18] == 0 && bytes[19] == 1
        }
        guard accepted else { return nil }

        // Data copies the shared buffer only when mutated. Swapping addresses
        // preserves IPv4 and transport checksums, including for fragments.
        var packet = input
        packet.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            bytes[15] = 1
            bytes[19] = 2
        }
        return packet
    }
}

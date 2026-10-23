import Foundation

enum LocalPacketReflection {
    static func reflect(_ input: Data) -> Data? {
        guard input.count >= 20 else { return nil }
        var packet = [UInt8](input)
        let headerLength = Int(packet[0] & 0x0f) * 4
        let length = Int(packet[2]) << 8 | Int(packet[3])
        guard packet[0] >> 4 == 4, headerLength >= 20,
              headerLength <= packet.count, length >= headerLength, length == packet.count,
              Array(packet[12..<16]) == [10, 7, 0, 2],
              Array(packet[16..<20]) == [10, 7, 0, 1] else { return nil }
        for offset in 0..<4 { packet.swapAt(12 + offset, 16 + offset) }
        // Address swapping preserves the IPv4 checksum and TCP/UDP pseudo-header
        // sums. Ports and payload remain intact, including fragmented packets.
        return Data(packet)
    }
}

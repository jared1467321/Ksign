import NetworkExtension

// A local IPv4 loopback route. No remote endpoint, DNS override, default route,
// credentials, or user traffic outside the dedicated /32 is needed.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let worker = DispatchQueue(label: "Ksign.local-packets")
    private var running = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.7.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.7.0.1", subnetMask: "255.255.255.255")]
        ipv4.excludedRoutes = [.default()]
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { completionHandler(error); return }
            if let error { completionHandler(error); return }
            self.worker.async {
                self.running = true
                self.readPackets()
                completionHandler(nil)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        worker.async {
            self.running = false
            completionHandler()
        }
    }

    private func readPackets() {
        guard running else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.worker.async {
                guard self.running else { return }
                var reflected: [Data] = []
                for (packet, family) in zip(packets, protocols) where family.int32Value == AF_INET {
                    if let packet = LocalPacketReflection.reflect(packet) { reflected.append(packet) }
                }
                if !reflected.isEmpty {
                    self.packetFlow.writePackets(reflected, withProtocols: Array(repeating: NSNumber(value: AF_INET), count: reflected.count))
                }
                self.readPackets()
            }
        }
    }
}

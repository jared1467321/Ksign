import SwiftUI
import UIKit
import Metal

enum NBAuroraInkMapFormat {
    static let width = 192
    static let height = 384
    static let framesPerSecond = 30
}

/// A scope owns its lease; the map keeps only a weak reference to it. Dropped
/// scopes cannot leave a display link running if onDisappear is missed.
@available(iOS 17.0, tvOS 17.0, *)
@MainActor
final class NBAuroraInkLease: ObservableObject {
    // The scope owns the lease without observing paint changes. Only the
    // small foreground view observes this separate paint object.
    let paint = NBAuroraInkPaint()
    var active = false
    var reduceMotion = false
}

@available(iOS 17.0, tvOS 17.0, *)
@MainActor
final class NBAuroraInkPaint: ObservableObject {
    @Published private(set) var frame: NBAuroraInkMap.Frame?

    fileprivate func receive(_ frame: NBAuroraInkMap.Frame?) {
        guard self.frame?.id != frame?.id else { return }
        self.frame = frame
    }
}

@available(iOS 17.0, tvOS 17.0, *)
@MainActor
final class NBAuroraInkMap {
    static let shared = NBAuroraInkMap()

    struct Frame {
        let id = UUID()
        let identity: NBAuroraShaderIdentity
        let argument: Shader.Argument
    }

    private(set) var animated: Frame?
    private(set) var still: Frame?

    private struct WeakLease {
        weak var value: NBAuroraInkLease?
    }

    private var leases: [ObjectIdentifier: WeakLease] = [:]
    private var displayLink: CADisplayLink?
    private var inFlight = false
    private var refreshPending = false
    private var unavailable = false
    private let worker = NBAuroraInkWorker()

    func update(_ lease: NBAuroraInkLease, active: Bool, reduceMotion: Bool) {
        lease.active = active
        lease.reduceMotion = reduceMotion
        if active {
            leases[ObjectIdentifier(lease)] = WeakLease(value: lease)
            lease.paint.receive(frame(for: AuroraSession.shared.identity.shaderIdentity,
                                      reduceMotion: reduceMotion))
        } else {
            leases.removeValue(forKey: ObjectIdentifier(lease))
            // Retained offscreen views release the live map and stop receiving
            // frames. Returning views get the current cached frame above.
            lease.paint.receive(nil)
        }
        refresh(advancing: false)
    }

    func frame(for identity: NBAuroraShaderIdentity, reduceMotion: Bool) -> Frame? {
        let frame = reduceMotion ? still : animated
        return frame?.identity == identity ? frame : nil
    }

    fileprivate func refresh(advancing: Bool = true) {
        leases = leases.filter { $0.value.value != nil }
        let clients = leases.values.compactMap(\.value).filter(\.active)
        let animates = clients.contains { !$0.reduceMotion }
        if animates && !unavailable {
            startClock()
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
        guard !clients.isEmpty, !unavailable else { return }
        let session = AuroraSession.shared
        let identity = session.identity.shaderIdentity
        let frozen = clients.contains { $0.reduceMotion } && still?.identity != identity
        guard frozen || (animates && (advancing || animated?.identity != identity)) else { return }
        guard !inFlight else {
            refreshPending = true
            return
        }
        let time = Float(session.time(at: Date(), reduceMotion: frozen))
        inFlight = true
        refreshPending = false
        worker.render(identity: identity.values, time: time) { [weak self] bytes in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                // A shuffle during GPU work must not publish the previous sky.
                if let bytes, identity == AuroraSession.shared.identity.shaderIdentity,
                   self.leases.values.contains(where: { $0.value?.active == true }) {
                    let frame = Frame(identity: identity, argument: .data(bytes))
                    if frozen { self.still = frame } else { self.animated = frame }
                    for lease in self.leases.values {
                        guard let client = lease.value, client.active,
                              client.reduceMotion == frozen else { continue }
                        client.paint.receive(frame)
                    }
                } else if bytes == nil {
                    // The foreground keeps its visible difference fallback.
                    self.unavailable = true
                    self.displayLink?.invalidate()
                    self.displayLink = nil
                }
                if self.refreshPending { self.refresh(advancing: false) }
            }
        }
    }

    private func startClock() {
        guard displayLink == nil else { return }
        let target = NBAuroraInkClock(owner: self)
        let link = CADisplayLink(target: target, selector: #selector(NBAuroraInkClock.fire(_:)))
        link.preferredFramesPerSecond = NBAuroraInkMapFormat.framesPerSecond
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
}

@available(iOS 17.0, tvOS 17.0, *)
@MainActor
private final class NBAuroraInkClock: NSObject {
    weak var owner: NBAuroraInkMap?
    init(owner: NBAuroraInkMap) { self.owner = owner }
    @objc func fire(_ link: CADisplayLink) {
        guard let owner else { link.invalidate(); return }
        owner.refresh()
    }
}

/// All Metal state is confined to this serial queue. Only immutable arguments
/// and independently owned color bytes cross the queue boundary.
@available(iOS 17.0, tvOS 17.0, *)
private final class NBAuroraInkWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "NimbleKit.auroraInkMap", qos: .userInitiated)
    private var backend: Backend?
    private var attemptedSetup = false

    private struct Backend {
        let queue: any MTLCommandQueue
        let pipeline: any MTLComputePipelineState
        let noise: any MTLTexture
        let output: any MTLTexture
    }

    func render(identity: [Float], time: Float, completion: @escaping @Sendable (Data?) -> Void) {
        queue.async {
            let image = autoreleasepool { self.render(identity: identity, time: time) }
            completion(image)
        }
    }

    private func makeBackend() -> Backend? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .module),
              let function = library.makeFunction(name: "auroraBuildInkMap"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        let noiseDescription = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 256, height: 256, mipmapped: false)
        noiseDescription.storageMode = .shared
        noiseDescription.usage = .shaderRead
        let outputDescription = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: NBAuroraInkMapFormat.width,
            height: NBAuroraInkMapFormat.height, mipmapped: false)
        outputDescription.storageMode = .shared
        outputDescription.usage = .shaderWrite
        guard let noise = device.makeTexture(descriptor: noiseDescription),
              let output = device.makeTexture(descriptor: outputDescription) else { return nil }
        AuroraNoiseCache.bytes.withUnsafeBytes {
            noise.replace(region: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0,
                          withBytes: $0.baseAddress!, bytesPerRow: 256)
        }
        return Backend(queue: queue, pipeline: pipeline, noise: noise, output: output)
    }

    private func render(identity: [Float], time: Float) -> Data? {
        if !attemptedSetup {
            attemptedSetup = true
            backend = makeBackend()
        }
        guard identity.count == 41, let backend,
              let command = backend.queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(backend.pipeline)
        encoder.setTexture(backend.output, index: 0)
        encoder.setTexture(backend.noise, index: 1)
        identity.withUnsafeBytes {
            encoder.setBytes($0.baseAddress!, length: $0.count, index: 0)
        }
        var time = time
        encoder.setBytes(&time, length: MemoryLayout<Float>.size, index: 1)
        let width = backend.output.width, height = backend.output.height
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        encoder.endEncoding()
        command.commit()
        // Wait and copy only on the worker queue. No screen capture, main-thread
        // wait, full-resolution texture, or growing queue of pending frames.
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            backend.output.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        // Raw data avoids image color-space conversions changing the ink RGB.
        return bytes
    }
}

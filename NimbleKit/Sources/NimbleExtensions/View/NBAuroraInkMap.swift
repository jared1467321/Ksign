import SwiftUI
import UIKit
import Metal

enum NBAuroraInkMapFormat {
    static let width = 192
    static let height = 384
    // The sky moves slowly; its complementary ink can sample at half the
    // backdrop cadence without reducing spatial detail or color saturation.
    static let framesPerSecond = 15
}

/// Full-width strips preserve horizontal overflow and inherited row ink. Round
/// outward to shared bands, with a band of spare rows on each side for glyph
/// overhang and both bilinear taps. These are original texels, never resampled.
struct NBAuroraInkRows: Hashable, Sendable {
    let first: Int
    let count: Int

    static let full = Self(first: 0, count: NBAuroraInkMapFormat.height)

    private init(first: Int, count: Int) {
        self.first = first
        self.count = count
    }

    init(frame: CGRect, window: CGRect) {
        guard NBAuroraTextVisibility.usable(frame), NBAuroraTextVisibility.usable(window) else {
            self = .full
            return
        }
        let height = NBAuroraInkMapFormat.height
        let band = 16
        let low = min(1, max(0, (frame.minY - window.minY) / window.height))
        let high = min(1, max(0, (frame.maxY - window.minY) / window.height))
        let first = max(0, (Int(floor(low * CGFloat(height) - 0.5)) / band - 1) * band)
        let end = min(height, (Int(floor(high * CGFloat(height) - 0.5)) / band + 2) * band)
        self.init(first: first, count: end - first)
    }
}

/// Immutable color strips are cropped and compared on the Metal worker. Main
/// only looks up a prepared sample and publishes changed sample identities.
@available(iOS 17.0, tvOS 17.0, *)
final class NBAuroraInkSample: @unchecked Sendable {
    let identity: NBAuroraShaderIdentity
    let rows: NBAuroraInkRows
    let bytes: Data
    let argument: Shader.Argument

    init(identity: NBAuroraShaderIdentity, rows: NBAuroraInkRows, bytes: Data) {
        self.identity = identity
        self.rows = rows
        self.bytes = bytes
        argument = .data(bytes)
    }
}

@available(iOS 17.0, tvOS 17.0, *)
final class NBAuroraInkFrame: @unchecked Sendable {
    let identity: NBAuroraShaderIdentity
    private let full: NBAuroraInkSample
    private let samples: [NBAuroraInkRows: NBAuroraInkSample]

    init(identity: NBAuroraShaderIdentity, bytes: Data, rows: Set<NBAuroraInkRows>,
         previous: NBAuroraInkFrame?) {
        self.identity = identity
        func sample(_ rows: NBAuroraInkRows, _ data: Data) -> NBAuroraInkSample {
            if let old = previous?.sample(for: rows), old.rows == rows,
               old.identity == identity, old.bytes == data { return old }
            return NBAuroraInkSample(identity: identity, rows: rows, bytes: data)
        }
        full = sample(.full, bytes)
        var strips: [NBAuroraInkRows: NBAuroraInkSample] = [:]
        let stride = NBAuroraInkMapFormat.width * 4
        // Only currently visible, unique strips are prepared. The immutable
        // frame never accumulates strips from previous scrolling positions.
        for rows in rows where rows != .full {
            let data = bytes.subdata(in: (rows.first * stride)..<((rows.first + rows.count) * stride))
            strips[rows] = sample(rows, data)
        }
        samples = strips
    }

    func sample(for rows: NBAuroraInkRows) -> NBAuroraInkSample {
        // A newly visible label (or scrolling over a frozen sky) can use the
        // exact full map until a matching strip is prepared. No resampling.
        samples[rows] ?? full
    }
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
    var rows = NBAuroraInkRows.full
}

@available(iOS 17.0, tvOS 17.0, *)
@MainActor
final class NBAuroraInkPaint: ObservableObject {
    @Published private(set) var sample: NBAuroraInkMap.Sample?

    fileprivate func receive(_ frame: NBAuroraInkMap.Frame?, rows: NBAuroraInkRows = .full) {
        let next = frame?.sample(for: rows)
        guard sample !== next else { return }
        sample = next
    }
}

@available(iOS 17.0, tvOS 17.0, *)
@MainActor
final class NBAuroraInkMap {
    static let shared = NBAuroraInkMap()

    typealias Sample = NBAuroraInkSample
    typealias Frame = NBAuroraInkFrame

    private(set) var animated: Frame?
    private(set) var still: Frame?

    private struct WeakLease {
        weak var value: NBAuroraInkLease?
    }

    private var leases: [ObjectIdentifier: WeakLease] = [:]
    private var displayLink: CADisplayLink?
    private var inFlight = false
    private var refreshPending = false
    private var refreshScheduled = false
    private var unavailable = false
    private var consecutiveFailures = 0
    private var isActive = true
    private var generation: UInt64 = 0
    private let worker = NBAuroraInkWorker()

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        generation &+= 1
        if active {
            // A failure while suspending must not disable ink for the session.
            unavailable = false
            consecutiveFailures = 0
        }
        refresh(advancing: active)
    }

    func update(_ lease: NBAuroraInkLease, active: Bool, reduceMotion: Bool) {
        if active && unavailable && !leases.values.contains(where: { $0.value?.active == true }) {
            // Give a returning presentation a fresh attempt, once, rather
            // than retrying for every label joining an already visible list.
            unavailable = false
            consecutiveFailures = 0
        }
        lease.active = active
        lease.reduceMotion = reduceMotion
        if active {
            leases[ObjectIdentifier(lease)] = WeakLease(value: lease)
            lease.paint.receive(frame(for: AuroraSession.shared.identity.shaderIdentity,
                                      reduceMotion: reduceMotion), rows: lease.rows)
        } else {
            leases.removeValue(forKey: ObjectIdentifier(lease))
            // Retained offscreen views release the live map and stop receiving
            // frames. Returning views get the current cached frame above.
            lease.paint.receive(nil)
        }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            // A batch of arriving/departing labels needs one client scan.
            self.refresh(advancing: false)
        }
    }

    func frame(for identity: NBAuroraShaderIdentity, reduceMotion: Bool) -> Frame? {
        let frame = reduceMotion ? still : animated
        return frame?.identity == identity ? frame : nil
    }

    fileprivate func refresh(advancing: Bool = true) {
        // Inspect weak leases without rebuilding a dictionary and two client
        // arrays on every frame and every label's visibility transition.
        var hasClients = false
        var animates = false
        var needsStill = false
        for (key, entry) in leases {
            guard let client = entry.value else {
                leases.removeValue(forKey: key)
                continue
            }
            guard client.active else { continue }
            hasClients = true
            if client.reduceMotion { needsStill = true } else { animates = true }
        }
        if isActive && animates && !unavailable {
            startClock()
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
        guard isActive, hasClients, !unavailable else { return }
        let session = AuroraSession.shared
        let identity = session.identity.shaderIdentity
        let frozen = needsStill && still?.identity != identity
        guard frozen || (animates && (advancing || animated?.identity != identity)) else { return }
        guard !inFlight else {
            refreshPending = true
            return
        }
        let time = Float(session.time(at: Date(), reduceMotion: frozen))
        inFlight = true
        refreshPending = false
        let generation = generation
        let rows = Set(leases.values.compactMap { entry -> NBAuroraInkRows? in
            guard let lease = entry.value, lease.active, lease.reduceMotion == frozen else { return nil }
            return lease.rows
        })
        worker.render(identity: identity, time: time, rows: rows,
                      previous: frozen ? still : animated) { [weak self] frame in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                guard generation == self.generation else {
                    // Discard work from before suspension, including failures.
                    // If already resumed, immediately sample the current sky.
                    self.refresh(advancing: true)
                    return
                }
                // A shuffle during GPU work must not publish the previous sky.
                if let frame, identity == AuroraSession.shared.identity.shaderIdentity,
                   self.leases.values.contains(where: { $0.value?.active == true }) {
                    self.consecutiveFailures = 0
                    if frozen { self.still = frame } else { self.animated = frame }
                    for lease in self.leases.values {
                        guard let client = lease.value, client.active,
                              client.reduceMotion == frozen else { continue }
                        client.paint.receive(frame, rows: client.rows)
                    }
                } else if frame == nil, identity == AuroraSession.shared.identity.shaderIdentity,
                          self.leases.values.contains(where: { $0.value?.active == true }) {
                    self.consecutiveFailures += 1
                    if self.consecutiveFailures < 2 {
                        self.refresh(advancing: true)
                        return
                    }
                    // Keep existing paint and stop after one retry. Another
                    // foreground/presentation return can try again.
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
    private let queue = DispatchQueue(label: "NimbleKit.auroraInkMap", qos: .utility)
    private var backend: Backend?
    private var attemptedSetup = false

    private struct Backend {
        let queue: any MTLCommandQueue
        let pipeline: any MTLComputePipelineState
        let noise: any MTLTexture
        let output: any MTLTexture
    }

    func render(identity: NBAuroraShaderIdentity, time: Float, rows: Set<NBAuroraInkRows>,
                previous: NBAuroraInkFrame?,
                completion: @escaping @Sendable (NBAuroraInkFrame?) -> Void) {
        queue.async {
            let frame = autoreleasepool { () -> NBAuroraInkFrame? in
                guard let bytes = self.render(identity: identity.values, time: time) else { return nil }
                return NBAuroraInkFrame(identity: identity, bytes: bytes, rows: rows, previous: previous)
            }
            if frame == nil {
                // Recreate failed Metal resources on the next bounded attempt.
                self.backend = nil
                self.attemptedSetup = false
            }
            completion(frame)
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

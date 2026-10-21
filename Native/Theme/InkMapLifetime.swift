import Foundation

// GPU work and platform drawing are boundary doubles. The shared map owner,
// lease management, weak clock and request scheduling run production source.
protocol ObservableObject {}
final class PublishCount { var writes = 0 }
@propertyWrapper struct Published<Value> {
    private var value: Value
    let projectedValue = PublishCount()
    init(wrappedValue: Value) { value = wrappedValue }
    var wrappedValue: Value {
        get { value }
        set { projectedValue.writes += 1; value = newValue }
    }
}
struct Shader {
    struct Argument {
        let bytes: Data
        static func data(_ bytes: Data) -> Self { Self(bytes: bytes) }
    }
}

// Identity generation and star drawing remain boundaries; the production
// session's foreground clock and measurement refresh scheduling run below.
struct AuroraTestIdentity {
    let shaderIdentity: NBAuroraShaderIdentity
    func starfieldSeed(stream: UInt64) -> UInt64 { stream }
}
enum AuroraIdentityGenerator {
    static func next() -> AuroraTestIdentity {
        AuroraTestIdentity(shaderIdentity: NBAuroraShaderIdentity(high: 0, low: 0))
    }
}
final class NBAuroraStarfield {}
struct NBAuroraStarfieldCache {
    func field(stream: UInt64, seed: UInt64, count: Int) -> NBAuroraStarfield { NBAuroraStarfield() }
}

// PRODUCTION_SESSION

extension AuroraSession {
    fileprivate var measurementRefreshPendingForTest: Bool { measurementRefreshPending }
    func shuffle(_ low: UInt64) {
        identity = AuroraTestIdentity(shaderIdentity: NBAuroraShaderIdentity(high: 0, low: low))
    }
}

final class NBAuroraInkWorker: @unchecked Sendable {
    struct Request: Sendable {
        let identity: [Float]
        let time: Float
        let completion: @Sendable (Data?) -> Void
    }
    @MainActor static var pending: [Request] = []
    func render(identity: [Float], time: Float, completion: @escaping @Sendable (Data?) -> Void) {
        MainActor.assumeIsolated {
            Self.pending.append(Request(identity: identity, time: time, completion: completion))
        }
    }
    @MainActor static func complete(_ bytes: Data? = Data([1])) {
        pending.removeFirst().completion(bytes)
    }
}

@MainActor
final class CADisplayLink {
    static var active: [CADisplayLink] = []
    private let target: NBAuroraInkClock
    var preferredFramesPerSecond = 0
    private(set) var invalidated = false
    fileprivate init(target: NBAuroraInkClock, selector: String) { self.target = target }
    func add(to: RunLoop, forMode: RunLoop.Mode) { Self.active.append(self) }
    func invalidate() {
        invalidated = true
        Self.active.removeAll { $0 === self }
    }
    func tick() { target.fire(self) }
}

// PRODUCTION_MAP
// PRODUCTION_ROW

extension NBAuroraInkMap {
    fileprivate var busyForTest: Bool { inFlight }
}

extension NBAuroraInkPaint {
    fileprivate var notificationsForTest: Int { $frame.writes }
}

@main
enum InkMapLifetimeTests {
    static func viewportEdges() {
        let window = CGRect(x: 0, y: 0, width: 400, height: 900)
        let list = CGRect(x: 10, y: 100, width: 380, height: 700)
        let viewport = NBAuroraTextViewport(frame: list, window: window)
        assert(viewport.clipping == list)
        // Safe-area content margins can overlap visible list content under
        // glass bars. Eligibility follows the actual list edges, including
        // a single visible point of a partially clipped label.
        for y in [CGFloat(81), 100, 120, 760, 799] {
            assert(NBAuroraTextVisibility.intersects(
                CGRect(x: 20, y: y, width: 200, height: 20), window: window, clipping: viewport.clipping))
        }
        for y in [CGFloat(80), 800, 920] {
            assert(!NBAuroraTextVisibility.intersects(
                CGRect(x: 20, y: y, width: 200, height: 20), window: window, clipping: viewport.clipping))
        }
        let parent = NBAuroraTextViewport(clipping: CGRect(x: 0, y: 140, width: 400, height: 560), window: window)
        let nested = NBAuroraTextViewport(frame: list, window: nil, parent: parent)
        assert(nested.clipping == CGRect(x: 10, y: 140, width: 380, height: 560) && nested.window == window,
               "Nested lists still honor parent clipping and inherit its window")
        assert(!NBAuroraTextVisibility.intersects(
            CGRect(x: 20, y: 110, width: 200, height: 20), window: window, clipping: nested.clipping))
        let outsideWindow = NBAuroraTextViewport(frame: CGRect(x: 0, y: 0, width: 400, height: 1000), window: window)
        assert(!NBAuroraTextVisibility.intersects(
            CGRect(x: 20, y: 950, width: 200, height: 20), window: window, clipping: outsideWindow.clipping))
        print("Viewport edges passed: visible top/bottom strips, partial labels, offscreen exclusion and nested clipping.")
    }

    @MainActor
    static func measurementRecovery() async {
        let session = AuroraSession()
        let identity = session.identity.shaderIdentity
        session.setActive(true)
        assert(session.measurementRevision == 0 && !session.measurementRefreshPendingForTest,
               "Initial appearance must not schedule redundant measurements")
        session.setActive(false)
        session.setActive(false)
        session.setActive(true)
        session.setActive(true)
        assert(session.measurementRevision == 0 && session.measurementRefreshPendingForTest,
               "Remeasure only after the foreground transition has settled")
        await settle { session.measurementRevision == 1 }
        assert(!session.measurementRefreshPendingForTest && session.identity.shaderIdentity == identity,
               "One return must refresh probes without shuffling the sky")
        let pausedTime = session.accumulatedTime
        assert(session.time(at: Date(), reduceMotion: false) >= pausedTime)
        assert(session.time(at: Date(), reduceMotion: true) == 1.8)

        session.setActive(false)
        session.setActive(true)
        session.setActive(false)
        await settle { !session.measurementRefreshPendingForTest }
        assert(session.measurementRevision == 1,
               "Going inactive again must cancel the queued measurement refresh")

        session.setActive(true)
        session.setActive(false)
        session.setActive(true)
        await settle { session.measurementRevision == 2 }
        assert(!session.measurementRefreshPendingForTest,
               "Rapid returns coalesce into one refresh of the currently active scene")
        session.randomize()
        session.setActive(true)
        assert(session.measurementRevision == 2 && !session.measurementRefreshPendingForTest,
               "Shuffling and duplicate activation must not rebuild probes")
        print("Measurement recovery passed: deferred foreground refresh, coalescing, cancelled inactive refresh and unchanged animation clock.")
    }

    @MainActor
    static func transientFailure() async {
        let map = NBAuroraInkMap(), scope = NBAuroraInkLease()
        map.update(scope, active: true, reduceMotion: false)
        NBAuroraInkWorker.complete(nil)
        await settle { !NBAuroraInkWorker.pending.isEmpty }
        assert(NBAuroraInkWorker.pending.count == 1,
               "A temporary render failure should get one bounded retry")
        NBAuroraInkWorker.complete(Data([21]))
        await settle { !map.busyForTest }
        assert(scope.paint.frame?.argument.bytes == Data([21]))
        map.update(scope, active: false, reduceMotion: false)
        assert(CADisplayLink.active.isEmpty)
    }

    @MainActor
    static func activityRecovery() async {
        let map = NBAuroraInkMap(), scope = NBAuroraInkLease()
        map.update(scope, active: true, reduceMotion: false)
        map.setActive(false)
        assert(CADisplayLink.active.isEmpty)
        // A late GPU failure from before backgrounding cannot poison recovery.
        map.setActive(true)
        assert(NBAuroraInkWorker.pending.count == 1, "Resume cannot overlap in-flight work")
        NBAuroraInkWorker.complete(nil)
        await settle { !NBAuroraInkWorker.pending.isEmpty }
        NBAuroraInkWorker.complete(Data([22]))
        await settle { !map.busyForTest }
        assert(scope.paint.frame?.argument.bytes == Data([22]))

        let paintID = scope.paint.frame!.id
        let notifications = scope.paint.notificationsForTest
        CADisplayLink.active[0].tick()
        map.setActive(false)
        NBAuroraInkWorker.complete(Data([23]))
        await settle { !map.busyForTest }
        assert(scope.paint.frame?.id == paintID && scope.paint.notificationsForTest == notifications,
               "Suspended work must neither replace nor clear existing paint")
        map.update(scope, active: false, reduceMotion: false)
        map.update(scope, active: true, reduceMotion: false)
        assert(NBAuroraInkWorker.pending.isEmpty && CADisplayLink.active.isEmpty,
               "Late label registration cannot restart GPU work while inactive")

        map.setActive(true)
        assert(NBAuroraInkWorker.pending.count == 1, "Resume refreshes even with a matching cached identity")
        map.setActive(true)
        assert(NBAuroraInkWorker.pending.count == 1)
        NBAuroraInkWorker.complete(nil)
        await settle { !NBAuroraInkWorker.pending.isEmpty }
        NBAuroraInkWorker.complete(nil)
        await settle { !map.busyForTest }
        for _ in 0..<100 { map.update(scope, active: true, reduceMotion: false) }
        assert(NBAuroraInkWorker.pending.isEmpty && CADisplayLink.active.isEmpty,
               "Persistent failures must stop after one retry")
        assert(scope.paint.frame?.id == paintID, "A failed refresh must preserve valid paint")

        map.setActive(false)
        map.setActive(true)
        assert(NBAuroraInkWorker.pending.count == 1, "Foregrounding renews the bounded recovery budget")
        NBAuroraInkWorker.complete(Data([24]))
        await settle { !map.busyForTest }
        assert(scope.paint.frame?.argument.bytes == Data([24]))
        map.update(scope, active: false, reduceMotion: false)
        assert(CADisplayLink.active.isEmpty)

        // Reduce Motion must recover too, without relying on display-link ticks.
        let frozenMap = NBAuroraInkMap(), frozenScope = NBAuroraInkLease()
        frozenMap.update(frozenScope, active: true, reduceMotion: true)
        NBAuroraInkWorker.complete(nil)
        await settle { !NBAuroraInkWorker.pending.isEmpty }
        NBAuroraInkWorker.complete(Data([25]))
        await settle { !frozenMap.busyForTest }
        assert(frozenScope.paint.frame?.argument.bytes == Data([25]) && CADisplayLink.active.isEmpty)
        frozenMap.setActive(false)
        frozenMap.setActive(true)
        assert(NBAuroraInkWorker.pending.isEmpty, "Frozen ink needs no redundant resume render")
        frozenMap.update(frozenScope, active: false, reduceMotion: true)
        print("Ink recovery passed: transient failure, stale suspension results, fresh resume, bounded retries and Reduce Motion.")
    }

    @MainActor
    static func rowTracking() async {
        let row = NBAuroraTextRowTracker()
        let window = CGRect(x: 10, y: 20, width: 400, height: 900)
        let viewport = NBAuroraTextViewport(clipping: CGRect(x: 10, y: 200, width: 400, height: 560),
                                          window: window)
        let clients = (0..<3).map { _ in NBAuroraRowTextClient() }
        let localFrames = [CGRect(x: 70, y: 5, width: 200, height: 20),
                           CGRect(x: 70, y: 30, width: 200, height: 20),
                           CGRect(x: 350, y: 20, width: 10, height: 15)]
        row.configure(viewport: viewport, active: true, reduceMotion: false)
        for (client, frame) in zip(clients, localFrames) {
            row.measure(client, localFrame: frame)
            row.setVisible(client, true)
        }
        row.move(to: NBAuroraTextRowGeometry(frame: CGRect(x: 20, y: 210, width: 380, height: 70),
                                            size: CGSize(width: 380, height: 70)))
        assert(clients.allSatisfy { $0.lease.active })
        assert(NBAuroraInkWorker.pending.count == 1, "One row movement must share one ink render")
        NBAuroraInkWorker.complete(Data([11]))
        await settle { clients.allSatisfy { $0.lease.paint.frame != nil } }
        for (client, local) in zip(clients, localFrames) {
            assert(client.placement.bounds == CGRect(x: -10 - local.minX, y: -190 - local.minY,
                                                     width: 400, height: 900))
        }
        let inkID = clients[0].lease.paint.frame!.id
        // Model a transition that leaves the measurement probe culled. A
        // lease-only resume cannot recover; the recreated probe must report
        // the same on-screen geometry again without any scroll displacement.
        let originalGeometry = NBAuroraTextRowGeometry(
            frame: CGRect(x: 20, y: 210, width: 380, height: 70), size: CGSize(width: 380, height: 70))
        assert(originalGeometry.clipped(to: viewport) == originalGeometry)
        assert(originalGeometry.clipped(to: nil) == originalGeometry)
        assert(originalGeometry.clipped(to: NBAuroraTextViewport(clipping: viewport.clipping, window: nil))
               == originalGeometry, "Keep raw geometry while the window measurement is pending")
        assert(originalGeometry.clipped(to: NBAuroraTextViewport(clipping: .null, window: window)).frame.isNull,
               "An unavailable viewport must not register live text")
        row.configure(viewport: viewport, active: false, reduceMotion: false)
        row.move(to: NBAuroraTextRowGeometry(frame: .null, size: .zero))
        row.configure(viewport: viewport, active: true, reduceMotion: false, refresh: true)
        assert(clients.allSatisfy { !$0.lease.active && $0.lease.paint.frame == nil })
        row.move(to: originalGeometry)
        assert(clients.allSatisfy { $0.lease.active && $0.lease.paint.frame?.id == inkID },
               "Fresh measurements must restore cached ink without scrolling")
        assert(NBAuroraInkWorker.pending.isEmpty,
               "Remeasuring must not trigger a redundant map render")
        // Tab entry can retain both a culled row and invalid local label
        // measurements. The appearance probes refresh both coordinate sets
        // at the original positions, without a shuffle or a scroll.
        row.configure(viewport: viewport, active: false, reduceMotion: false)
        row.move(to: NBAuroraTextRowGeometry(frame: .null, size: .zero))
        for client in clients {
            row.setVisible(client, false)
            row.measure(client, localFrame: .null)
        }
        row.configure(viewport: viewport, active: true, reduceMotion: false, refresh: true)
        for client in clients { row.setVisible(client, true) }
        assert(clients.allSatisfy { !$0.lease.active && $0.lease.paint.frame == nil })
        row.move(to: originalGeometry)
        assert(clients.allSatisfy { !$0.lease.active }, "The row alone cannot recover invalid label measurements")
        for (client, frame) in zip(clients, localFrames) { row.measure(client, localFrame: frame) }
        assert(clients.allSatisfy { $0.lease.active && $0.lease.paint.frame?.id == inkID })
        assert(NBAuroraInkWorker.pending.isEmpty, "Tab reentry reuses cached ink")
        // No label remeasurement: one row movement updates all three offsets.
        row.move(to: NBAuroraTextRowGeometry(frame: CGRect(x: 20, y: 175, width: 380, height: 70),
                                            size: CGSize(width: 380, height: 70)))
        assert(!clients[0].lease.active && clients[1].lease.active && clients[2].lease.active,
               "A partially visible row still clips each label independently")
        assert(clients[1].lease.paint.frame?.id == inkID && NBAuroraInkWorker.pending.isEmpty)
        row.move(to: NBAuroraTextRowGeometry(frame: CGRect(x: 20, y: 730, width: 380, height: 70),
                                            size: CGSize(width: 380, height: 70)))
        assert(clients[0].lease.active && !clients[1].lease.active && clients[2].lease.active,
               "The bottom edge keeps visible titles and partial icons active while excluding an offscreen subtitle")
        assert(clients[0].lease.paint.frame?.id == inkID && clients[2].lease.paint.frame?.id == inkID)
        let counts = clients.map { $0.placement.$bounds.writes }
        row.move(to: NBAuroraTextRowGeometry(frame: .null, size: .zero))
        assert(clients.allSatisfy { !$0.lease.active && $0.lease.paint.frame == nil })
        row.move(to: NBAuroraTextRowGeometry(frame: .null, size: .zero))
        assert(clients.map { $0.placement.$bounds.writes } == counts,
               "Offscreen movement must not publish placement changes")
        assert(CADisplayLink.active.isEmpty)

        // Selection scales the row by 0.98. Shader bounds must invert that
        // transform, rather than treating local points as window points.
        let scaled = NBAuroraTextRowGeometry(frame: CGRect(x: 24, y: 214, width: 372.4, height: 68.6),
                                             size: CGSize(width: 380, height: 70))
        row.move(to: scaled)
        for (client, local) in zip(clients, localFrames) {
            let bounds = client.placement.bounds
            let global = scaled.globalFrame(for: local)
            let p = CGPoint(x: 3, y: 7)
            let u = (p.x - bounds.minX) / bounds.width
            let v = (p.y - bounds.minY) / bounds.height
            assert(abs(u - (global.minX + p.x * 0.98 - window.minX) / window.width) < 0.000001)
            assert(abs(v - (global.minY + p.y * 0.98 - window.minY) / window.height) < 0.000001)
            assert(client.lease.paint.frame?.id == inkID, "Reentry must reuse current ink")
        }
        let changed = CGRect(x: 90, y: 8, width: 180, height: 40)
        row.measure(clients[0], localFrame: changed)
        assert(clients[0].placement.bounds == scaled.inkBounds(for: changed, window: window),
               "Wrapping/edit layout must update a label's local offset")
        row.configure(viewport: viewport, active: false, reduceMotion: false)
        assert(CADisplayLink.active.isEmpty && clients.allSatisfy { !$0.lease.active })
        row.configure(viewport: viewport, active: true, reduceMotion: true)
        assert(CADisplayLink.active.isEmpty && NBAuroraInkWorker.pending.count == 1)
        NBAuroraInkWorker.complete(Data([12]))
        await settle { clients.allSatisfy { $0.lease.paint.frame?.argument.bytes == Data([12]) } }
        for client in clients { row.setVisible(client, false) }
        assert(clients.allSatisfy { $0.lease.paint.frame == nil })

        let rows = (0..<103).map { _ in NBAuroraTextRowTracker() }
        let labels = rows.map { tracker in
            tracker.configure(viewport: viewport, active: true, reduceMotion: false)
            return localFrames.map { frame in
                let client = NBAuroraRowTextClient()
                tracker.measure(client, localFrame: frame)
                tracker.setVisible(client, true)
                return client
            }
        }
        func scroll(_ offset: CGFloat) {
            for (index, tracker) in rows.enumerated() {
                let frame = CGRect(x: 20, y: 210 + CGFloat(index) * 70 - offset, width: 380, height: 70)
                tracker.move(to: NBAuroraTextRowGeometry(frame: frame, size: frame.size).clipped(to: viewport))
            }
        }
        scroll(0)
        assert(labels.flatMap { $0 }.filter { $0.lease.active }.count == 24)
        let offscreenWrites = labels.dropFirst(8).flatMap { $0 }.map { $0.placement.$bounds.writes }
        scroll(5)
        assert(labels.dropFirst(8).flatMap { $0 }.map { $0.placement.$bounds.writes } == offscreenWrites)
        scroll(700)
        assert(labels.prefix(10).flatMap { $0 }.allSatisfy { !$0.lease.active })
        assert(labels[10..<18].flatMap { $0 }.allSatisfy { $0.lease.active })
        assert(labels.dropFirst(18).flatMap { $0 }.allSatisfy { !$0.lease.active })
        for tracker in rows { tracker.configure(viewport: viewport, active: false, reduceMotion: false) }
        assert(CADisplayLink.active.isEmpty && NBAuroraInkWorker.pending.isEmpty)
        print("Row tracking passed: shared movement, per-label clipping, offscreen suppression, cached reentry, selection scale, layout changes and Reduce Motion.")
    }

    @MainActor
    static func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try! await Task.sleep(for: .milliseconds(1))
        }
        preconditionFailure("Map completion did not settle")
    }

    @MainActor
    static func main() async {
        viewportEdges()
        await measurementRecovery()
        // Deterministic time input for the map coordinator tests below.
        AuroraSession.shared.activeStart = nil
        AuroraSession.shared.accumulatedTime = 12
        await transientFailure()
        await activityRecovery()
        await rowTracking()
        let map = NBAuroraInkMap()
        let scopes = (0..<100).map { _ in NBAuroraInkLease() }
        for scope in scopes { map.update(scope, active: true, reduceMotion: false) }
        assert(CADisplayLink.active.count == 1 && NBAuroraInkWorker.pending.count == 1)
        assert(CADisplayLink.active[0].preferredFramesPerSecond == NBAuroraInkMapFormat.framesPerSecond)
        for _ in 0..<50 { CADisplayLink.active[0].tick() }
        assert(NBAuroraInkWorker.pending.count == 1, "Slow work must never build a frame backlog")
        NBAuroraInkWorker.complete()
        await settle { !map.busyForTest }
        assert(map.animated?.argument.bytes == Data([1]))
        assert(scopes.allSatisfy { $0.paint.frame?.id == map.animated?.id })
        assert(NBAuroraInkWorker.pending.isEmpty, "Client registration must not cause redundant renders")
        for scope in scopes { map.update(scope, active: true, reduceMotion: false) }
        assert(NBAuroraInkWorker.pending.isEmpty)
        CADisplayLink.active[0].tick()
        for scope in scopes { map.update(scope, active: false, reduceMotion: false) }
        assert(CADisplayLink.active.isEmpty)
        assert(scopes.allSatisfy { $0.paint.frame == nil })
        NBAuroraInkWorker.complete(Data([2]))
        await settle { !map.busyForTest }
        assert(map.animated?.argument.bytes == Data([1]), "Offscreen work must not publish")

        // Model 103 retained List rows with only eight intersecting its actual
        // scroll viewport. Use production clipping and production delivery.
        let listMap = NBAuroraInkMap()
        let rows = (0..<103).map { _ in NBAuroraInkLease() }
        let window = CGRect(x: 0, y: 0, width: 400, height: 900)
        let clipping = CGRect(x: 0, y: 200, width: 400, height: 560)
        func updateRows(scroll: CGFloat) {
            for (index, row) in rows.enumerated() {
                let rect = CGRect(x: 0, y: 200 + CGFloat(index) * 70 - scroll, width: 400, height: 70)
                let visible = NBAuroraTextVisibility.intersects(rect, window: window, clipping: clipping)
                listMap.update(row, active: visible, reduceMotion: false)
            }
        }
        updateRows(scroll: 0)
        assert(NBAuroraInkWorker.pending.count == 1)
        NBAuroraInkWorker.complete(Data([7]))
        await settle { !listMap.busyForTest }
        assert(rows.filter { $0.paint.frame != nil }.count == 8)
        let firstID = listMap.animated!.id
        assert(rows.prefix(8).allSatisfy { $0.paint.frame?.id == firstID })
        assert(rows.dropFirst(8).allSatisfy { $0.paint.frame == nil })
        assert(rows.dropFirst(8).allSatisfy { $0.paint.notificationsForTest == 0 })
        let firstCounts = rows.map { $0.paint.notificationsForTest }
        CADisplayLink.active[0].tick()
        NBAuroraInkWorker.complete(Data([8]))
        await settle { !listMap.busyForTest }
        assert(rows.prefix(8).allSatisfy { $0.paint.frame?.id == listMap.animated?.id })
        assert(rows.dropFirst(8).allSatisfy { $0.paint.frame == nil })
        for index in rows.indices {
            assert(rows[index].paint.notificationsForTest == firstCounts[index] + (index < 8 ? 1 : 0))
        }
        updateRows(scroll: 700)
        assert(NBAuroraInkWorker.pending.isEmpty, "Entering rows must reuse the current map immediately")
        assert(rows[10..<18].allSatisfy { $0.paint.frame?.id == listMap.animated?.id })
        assert(rows.prefix(10).allSatisfy { $0.paint.frame == nil })
        assert(rows.dropFirst(18).allSatisfy { $0.paint.frame == nil })
        let scrolledCounts = rows.map { $0.paint.notificationsForTest }
        CADisplayLink.active[0].tick()
        NBAuroraInkWorker.complete(Data([9]))
        await settle { !listMap.busyForTest }
        assert(rows.filter { $0.paint.frame != nil }.count == 8)
        assert(rows[10..<18].allSatisfy { $0.paint.frame?.id == listMap.animated?.id })
        for index in rows.indices {
            let visible = (10..<18).contains(index)
            assert(rows[index].paint.notificationsForTest == scrolledCounts[index] + (visible ? 1 : 0))
        }
        for row in rows { listMap.update(row, active: false, reduceMotion: false) }
        assert(CADisplayLink.active.isEmpty && rows.allSatisfy { $0.paint.frame == nil })

        assert(!NBAuroraTextVisibility.intersects(.null, window: window))
        assert(!NBAuroraTextVisibility.intersects(.zero, window: window))
        assert(!NBAuroraTextVisibility.intersects(window, window: .zero))
        assert(!NBAuroraTextVisibility.intersects(window, window: window, clipping: .null))
        assert(!NBAuroraTextVisibility.intersects(CGRect(x: 0, y: 760, width: 100, height: 40),
                                                window: window, clipping: clipping))
        assert(NBAuroraTextVisibility.intersects(CGRect(x: 0, y: 759, width: 100, height: 40),
                                               window: window, clipping: clipping))
        assert(!NBAuroraTextVisibility.intersects(CGRect(x: 450, y: 250, width: 100, height: 40),
                                                window: window, clipping: clipping))

        let shuffleMap = NBAuroraInkMap(), shuffleScope = NBAuroraInkLease()
        let oldIdentity = AuroraSession.shared.identity.shaderIdentity
        shuffleMap.update(shuffleScope, active: true, reduceMotion: false)
        AuroraSession.shared.shuffle(17)
        shuffleMap.update(shuffleScope, active: true, reduceMotion: false)
        NBAuroraInkWorker.complete()
        await settle { !NBAuroraInkWorker.pending.isEmpty }
        assert(shuffleMap.animated == nil, "A previous sky must not arrive after a shuffle")
        assert(NBAuroraInkWorker.pending[0].identity == AuroraSession.shared.identity.shaderIdentity.values)
        NBAuroraInkWorker.complete(Data([3]))
        await settle { !shuffleMap.busyForTest }
        assert(shuffleMap.frame(for: oldIdentity, reduceMotion: false) == nil)
        assert(shuffleMap.frame(for: AuroraSession.shared.identity.shaderIdentity, reduceMotion: false) != nil)
        shuffleMap.update(shuffleScope, active: false, reduceMotion: false)

        let frozenMap = NBAuroraInkMap(), frozenScope = NBAuroraInkLease()
        frozenMap.update(frozenScope, active: true, reduceMotion: true)
        assert(CADisplayLink.active.isEmpty && NBAuroraInkWorker.pending[0].time == 1.8)
        NBAuroraInkWorker.complete(Data([4]))
        await settle { !frozenMap.busyForTest }
        for _ in 0..<100 { frozenMap.update(frozenScope, active: true, reduceMotion: true) }
        assert(NBAuroraInkWorker.pending.isEmpty && frozenMap.animated == nil)
        let movingScope = NBAuroraInkLease()
        frozenMap.update(movingScope, active: true, reduceMotion: false)
        assert(NBAuroraInkWorker.pending[0].time == 12 && CADisplayLink.active.count == 1)
        NBAuroraInkWorker.complete(Data([5]))
        await settle { !frozenMap.busyForTest }
        assert(frozenMap.still?.argument.bytes == Data([4]), "Motion must not replace the frozen map")
        assert(frozenScope.paint.frame?.id == frozenMap.still?.id)
        assert(movingScope.paint.frame?.id == frozenMap.animated?.id)
        frozenMap.update(movingScope, active: false, reduceMotion: false)
        AuroraSession.shared.shuffle(42)
        frozenMap.update(frozenScope, active: true, reduceMotion: true)
        assert(CADisplayLink.active.isEmpty && NBAuroraInkWorker.pending[0].time == 1.8)
        NBAuroraInkWorker.complete(Data([6]))
        await settle { !frozenMap.busyForTest }
        assert(frozenMap.still?.argument.bytes == Data([6]))
        frozenMap.update(frozenScope, active: false, reduceMotion: true)

        let orphanMap = NBAuroraInkMap()
        var orphanScope: NBAuroraInkLease? = NBAuroraInkLease()
        orphanMap.update(orphanScope!, active: true, reduceMotion: false)
        NBAuroraInkWorker.complete()
        await settle { !orphanMap.busyForTest }
        weak var retiredScope = orphanScope
        orphanScope = nil
        assert(retiredScope == nil)
        CADisplayLink.active[0].tick()
        assert(CADisplayLink.active.isEmpty && NBAuroraInkWorker.pending.isEmpty)

        var disposable: NBAuroraInkMap? = NBAuroraInkMap()
        disposable!.update(shuffleScope, active: true, reduceMotion: false)
        weak var retiredOwner = disposable
        disposable = nil
        assert(retiredOwner == nil, "A clock and pending work must not retain their map owner")
        CADisplayLink.active[0].tick()
        assert(CADisplayLink.active.isEmpty)
        NBAuroraInkWorker.complete()

        let failedMap = NBAuroraInkMap()
        failedMap.update(shuffleScope, active: true, reduceMotion: false)
        NBAuroraInkWorker.complete(nil)
        await settle { !NBAuroraInkWorker.pending.isEmpty }
        NBAuroraInkWorker.complete(nil)
        await settle { !failedMap.busyForTest }
        for _ in 0..<100 { failedMap.update(shuffleScope, active: true, reduceMotion: false) }
        assert(failedMap.animated == nil && CADisplayLink.active.isEmpty && NBAuroraInkWorker.pending.isEmpty)
        failedMap.update(shuffleScope, active: false, reduceMotion: false)
        failedMap.update(shuffleScope, active: true, reduceMotion: false)
        assert(NBAuroraInkWorker.pending.count == 1, "Returning to a presentation can recover failed ink")
        NBAuroraInkWorker.complete(Data([26]))
        await settle { !failedMap.busyForTest }
        assert(shuffleScope.paint.frame?.argument.bytes == Data([26]))
        failedMap.update(shuffleScope, active: false, reduceMotion: false)
        print("Shared ink-map lifecycle tests passed: 100 scopes share one clock/render; 103 retained rows deliver only to eight visible paints, reenter with the latest map, and release offscreen buffers; clipping, no backlog/redundant frames, stale rejection, frozen/mixed motion, weak ownership, and bounded failure.")
    }
}

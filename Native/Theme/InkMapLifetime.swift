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

// Execute the production viewport reader's queued reporting and deduplication.
// UIKit layout/conversion itself remains a platform boundary.
struct UIColor { static let clear = UIColor() }
@MainActor class UIView {
    weak var window: UIView?
    weak var superview: UIView?
    var isHidden = false
    var alpha: CGFloat = 1
    var clipsToBounds = false
    var windowScale = CGSize(width: 1, height: 1)
    var bounds: CGRect
    var windowOrigin = CGPoint.zero
    var isUserInteractionEnabled = true
    var backgroundColor: UIColor?
    init(frame: CGRect) { bounds = CGRect(origin: .zero, size: frame.size) }
    func convert(_ rect: CGRect, to: UIView) -> CGRect {
        CGRect(x: windowOrigin.x + rect.minX * windowScale.width,
               y: windowOrigin.y + rect.minY * windowScale.height,
               width: rect.width * windowScale.width, height: rect.height * windowScale.height)
    }
    func didMoveToWindow() {}
    func layoutSubviews() {}
    func convert(_ point: CGPoint, to: UIView) -> CGPoint {
        CGPoint(x: windowOrigin.x + point.x, y: windowOrigin.y + point.y)
    }
}

// PRODUCTION_VIEWPORT

extension AuroraViewportView {
    fileprivate var pendingForTest: Bool { pending }
}

// PRODUCTION_SESSION

extension AuroraSession {
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
    private let target: AnyObject
    var preferredFramesPerSecond = 0
    private(set) var invalidated = false
    fileprivate init(target: AnyObject, selector: String) { self.target = target }
    func add(to: RunLoop, forMode: RunLoop.Mode) { Self.active.append(self) }
    func invalidate() {
        invalidated = true
        Self.active.removeAll { $0 === self }
    }
    func tick() {
        if let target = target as? NBAuroraInkClock { target.fire(self) }
        if let target = target as? NBAuroraTextLayoutTick { target.fire(self) }
    }
}

// PRODUCTION_MAP
// PRODUCTION_ATTACHMENT

extension NBAuroraTextLayoutClock {
    fileprivate var linkForTest: CADisplayLink? { displayLink }
}

extension NBAuroraInkMap {
    fileprivate var busyForTest: Bool { inFlight }
}

extension NBAuroraInkPaint {
    fileprivate var notificationsForTest: Int { $frame.writes }
}

@main
enum InkMapLifetimeTests {
    @MainActor
    static func viewportReporting() async {
        let view = AuroraViewportView(frame: .zero)
        let window = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 900))
        var reports: [AuroraViewport] = []
        var requests: [UUID?] = []
        view.onChange = { reports.append($0); requests.append(view.reportID) }
        let first = UUID()
        view.reportID = first
        view.scheduleReport()
        await settle { !view.pendingForTest }
        assert(reports.isEmpty, "A request before window attachment must wait for layout")
        view.window = window
        view.didMoveToWindow()
        await settle { !view.pendingForTest }
        assert(reports.isEmpty, "A zero-sized reader must not complete readiness")
        view.bounds.size = CGSize(width: 400, height: 600)
        view.windowOrigin = CGPoint(x: 0, y: 200)
        view.layoutSubviews()
        await settle { reports.count == 1 }
        assert(requests == [first] && reports[0].origin == view.windowOrigin)

        for _ in 0..<100 { view.scheduleReport(); view.layoutSubviews() }
        await settle { !view.pendingForTest }
        assert(reports.count == 1, "Unchanged ordinary layouts must not refresh labels")
        // One appearance/foreground request must replay unchanged positions.
        let latest = UUID()
        for _ in 0..<100 { view.reportID = UUID(); view.scheduleReport() }
        view.reportID = latest
        view.scheduleReport()
        await settle { reports.count == 2 }
        assert(requests.last! == latest && reports[0] == reports[1],
               "Coalesce queued requests into one report for the newest identity")

        view.bounds.size.height = 350
        view.layoutSubviews()
        await settle { reports.count == 3 }
        assert(reports[2] == reports[1], "A drawer height change must report even with unchanged window/origin")
        view.windowOrigin.y = 300
        view.layoutSubviews()
        await settle { reports.count == 4 }
        assert(reports.last!.origin.y == 300)

        view.reportID = UUID()
        view.scheduleReport()
        view.window = nil
        view.didMoveToWindow()
        await settle { !view.pendingForTest }
        assert(reports.count == 4, "A detached queued request must not publish")
        view.window = window
        view.didMoveToWindow()
        await settle { reports.count == 5 }
        assert(reports[4] == reports[3], "Reattachment must recover without scrolling")
        view.onChange = nil
        print("Viewport reporting passed: late window/layout, unchanged-position replay, 100 coalesced requests, detent resizing and reattachment.")
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
    static func attachmentLifecycle() async {
        let clock = NBAuroraTextLayoutClock.shared
        let map = NBAuroraInkMap.shared
        let window = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 900))
        let clip = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 560))
        clip.windowOrigin.y = 200
        clip.clipsToBounds = true
        clip.superview = window
        let anchor = NBAuroraTextAnchorView(frame: .zero)
        let attachment = NBAuroraTextAttachment()
        anchor.attachment = attachment
        anchor.superview = clip
        clock.register(anchor)
        assert(clock.linkForTest == nil, "An unattached label must not start a clock")
        anchor.window = window
        anchor.didMoveToWindow()
        let link = clock.linkForTest!
        for _ in 0..<10 { clock.register(anchor) }
        assert(clock.linkForTest === link && CADisplayLink.active.count == 1,
               "All labels share one layout clock; updates must not add clocks")
        link.tick()
        assert(!attachment.lease.active && NBAuroraInkWorker.pending.isEmpty,
               "A provisional zero-size layout must wait without starting GPU work")

        // Deliberately deliver NO layoutSubviews/onAppear/geometry callback.
        // Native layout can settle after SwiftUI has sent its initial events.
        anchor.bounds.size = CGSize(width: 200, height: 20)
        anchor.windowOrigin = CGPoint(x: 90, y: 225)
        link.tick()
        assert(attachment.lease.active && NBAuroraInkWorker.pending.count == 1,
               "The first usable native layout must start ink without user interaction")
        NBAuroraInkWorker.complete(Data([30]))
        await settle { !map.busyForTest }
        assert(attachment.placement.bounds == CGRect(x: -90, y: -225, width: 400, height: 900))
        let inkID = attachment.lease.paint.frame!.id
        let placementWrites = attachment.placement.$bounds.writes
        let paintWrites = attachment.lease.paint.notificationsForTest
        for _ in 0..<60 { link.tick() }
        assert(attachment.placement.$bounds.writes == placementWrites
               && attachment.lease.paint.notificationsForTest == paintWrites,
               "Unchanged layout ticks must not publish or re-register ink")

        clip.isHidden = true
        link.tick()
        assert(!attachment.lease.active && attachment.lease.paint.frame == nil)
        clip.isHidden = false
        link.tick()
        assert(attachment.lease.paint.frame?.id == inkID,
               "Showing a retained tab must recover without a SwiftUI appearance callback")
        clip.alpha = 0
        link.tick()
        assert(!attachment.lease.active)
        clip.alpha = 1
        clip.bounds.size.height = 1
        link.tick()
        assert(!attachment.lease.active)
        clip.bounds.size.height = 560
        link.tick()
        assert(attachment.lease.paint.frame?.id == inkID,
               "Expanding a drawer must activate stationary labels")

        anchor.windowOrigin.y = 800
        link.tick()
        assert(!attachment.lease.active)
        anchor.windowOrigin.y = 759
        link.tick()
        assert(attachment.lease.active, "One visible point at a clip edge is eligible")
        anchor.windowOrigin.y = 225
        anchor.windowScale = CGSize(width: 0.98, height: 0.98)
        link.tick()
        let bounds = attachment.placement.bounds
        assert(abs(bounds.minX + 90 / 0.98) < 0.000001)
        assert(abs(bounds.width - 400 / 0.98) < 0.000001,
               "Selection transforms must preserve window-aligned ink")

        anchor.reduceMotion = true
        link.tick()
        assert(NBAuroraInkWorker.pending.count == 1 && CADisplayLink.active.count == 1,
               "Reduce Motion keeps layout tracking but stops the animated map clock")
        NBAuroraInkWorker.complete(Data([31]))
        await settle { !map.busyForTest }
        assert(attachment.lease.paint.frame?.argument.bytes == Data([31]))
        for _ in 0..<60 { link.tick() }
        assert(NBAuroraInkWorker.pending.isEmpty)
        let oldIdentity = AuroraSession.shared.identity.shaderIdentity
        AuroraSession.shared.shuffle(123)
        link.tick()
        assert(NBAuroraInkWorker.pending.count == 1,
               "Shuffling must refresh frozen ink even without an animated map clock")
        NBAuroraInkWorker.complete(Data([32]))
        await settle { !map.busyForTest }
        assert(attachment.lease.paint.frame?.identity != oldIdentity)
        anchor.reduceMotion = false
        link.tick()
        assert(NBAuroraInkWorker.pending.count == 1)
        NBAuroraInkWorker.complete(Data([33]))
        await settle { !map.busyForTest }
        let resumedInkID = attachment.lease.paint.frame!.id

        map.setActive(false)
        clock.setActive(false)
        assert(CADisplayLink.active.isEmpty && !attachment.lease.active)
        clock.register(anchor)
        assert(CADisplayLink.active.isEmpty, "Background updates cannot restart layout work")
        map.setActive(true)
        clock.setActive(true)
        clock.linkForTest!.tick()
        assert(attachment.lease.active && attachment.lease.paint.frame?.id == resumedInkID)
        anchor.window = nil
        anchor.didMoveToWindow()
        assert(CADisplayLink.active.isEmpty && attachment.lease.paint.frame == nil)

        // Weak registration must not keep removed UIKit anchors alive.
        var orphan: NBAuroraTextAnchorView? = NBAuroraTextAnchorView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        orphan!.attachment = attachment
        orphan!.window = window
        orphan!.didMoveToWindow()
        let orphanLink = clock.linkForTest!
        orphanLink.tick()
        assert(attachment.lease.active)
        weak var retired = orphan
        orphan = nil
        assert(retired == nil)
        orphanLink.tick()
        assert(CADisplayLink.active.isEmpty && NBAuroraInkWorker.pending.isEmpty && !attachment.lease.active)
        print("Attachment lifecycle passed: delayed first layout with no callbacks, stationary tab/drawer visibility, clipping, scales, unchanged-frame suppression, Reduce Motion and shuffle, background/resume, detachment and weak cleanup.")
    }

    @MainActor
    static func attachedListVisibility() async {
        let clock = NBAuroraTextLayoutClock.shared
        let map = NBAuroraInkMap.shared
        let window = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 900))
        let clip = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 560))
        clip.windowOrigin.y = 200
        clip.clipsToBounds = true
        clip.superview = window
        let clients = (0..<309).map { _ in NBAuroraTextAttachment() }
        let anchors = clients.enumerated().map { index, client in
            let view = NBAuroraTextAnchorView(frame: CGRect(x: 0, y: 0, width: 100, height: 15))
            view.attachment = client
            view.superview = clip
            view.window = window
            view.windowOrigin = CGPoint(x: 20, y: 205 + (index / 3) * 70 + (index % 3) * 20)
            view.didMoveToWindow()
            return view
        }
        let link = clock.linkForTest!
        link.tick()
        if !NBAuroraInkWorker.pending.isEmpty {
            NBAuroraInkWorker.complete(Data([34]))
            await settle { !map.busyForTest }
        }
        assert(clients.filter { $0.lease.active }.count == 24)
        assert(CADisplayLink.active.count == 2, "309 anchors share one layout clock and one map clock")
        let offscreenWrites = clients.dropFirst(24).map { $0.placement.$bounds.writes }
        for view in anchors { view.windowOrigin.y -= 1 }
        link.tick()
        assert(clients.dropFirst(24).map { $0.placement.$bounds.writes } == offscreenWrites)
        assert(clients.dropFirst(24).allSatisfy { $0.lease.paint.notificationsForTest == 0 },
               "Retained offscreen anchors must never receive paint")
        for view in anchors { view.windowOrigin.y -= 699 }
        link.tick()
        assert(clients.prefix(30).allSatisfy { !$0.lease.active })
        assert(clients[30..<54].allSatisfy { $0.lease.active && $0.lease.paint.frame != nil })
        assert(clients.dropFirst(54).allSatisfy { !$0.lease.active })
        assert(NBAuroraInkWorker.pending.isEmpty, "Scroll reentry must reuse the current map")
        for view in anchors { view.window = nil; view.didMoveToWindow() }
        assert(CADisplayLink.active.isEmpty && clients.allSatisfy { $0.lease.paint.frame == nil })
        print("Attached list visibility passed: 103 retained rows / 309 labels share two clocks; only 24 visible labels receive paint, offscreen placement is silent, and scrolling reuses cached ink.")
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
        await viewportReporting()
        // Deterministic time input for the map coordinator tests below.
        AuroraSession.shared.activeStart = nil
        AuroraSession.shared.accumulatedTime = 12
        await transientFailure()
        await activityRecovery()
        await attachmentLifecycle()
        await attachedListVisibility()
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

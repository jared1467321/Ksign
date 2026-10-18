import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// UIKit/Combine doubles only. The registry, visibility calculation and anchor
// lifecycle are extracted from production by test_themes.py.
public protocol ObservableObject {}
@propertyWrapper public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
public enum NBThemeRole { case background, text }
public struct NBThemeColor: Equatable {}
private struct TestPath {
    let bounds: CGRect
    func contains(_ point: CGPoint) -> Bool { bounds.contains(point) }
}
@MainActor
private final class TestClip {
    func contains(_ point: CGPoint, in window: UIWindow) -> Bool { true }
}
fileprivate struct NBThemePaintMetadata {
    var ancestors: [UUID] = []
    var layer: [Int] = []
    var alpha: Double = 1
    var editable = true
    var path: ((CGRect) -> TestPath)?
    var clips: [TestClip] = []
    var outset: CGFloat = 0
}
public struct NBThemeInspectorTargetFrame {
    public let role: NBThemeRole
    public let frame: CGRect
    public let elementID: String?
    public let initialColor: NBThemeColor?
    fileprivate var metadata: NBThemePaintMetadata?
    fileprivate var pathContains: ((CGPoint) -> Bool)?
}
@MainActor
public class UIView {
    weak var superview: UIView?
    var bounds = CGRect(x: 0, y: 0, width: 54, height: 54)
    var origin = CGPoint.zero
    var alpha: CGFloat = 1
    var isHidden = false
    var clipsToBounds = false
    var conversions = 0
    var window: UIWindow? { superview?.window }
    func didMoveToWindow() {}
    func layoutSubviews() {}
    func isDescendant(of view: UIView) -> Bool {
        superview === view || (superview?.isDescendant(of: view) ?? false)
    }
    func convert(_ rect: CGRect, to window: UIWindow) -> CGRect {
        conversions += 1
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }
    func convert(_ point: CGPoint, from window: UIWindow) -> CGPoint {
        CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }
}
@MainActor
public final class UIWindow: UIView {
    override var window: UIWindow? { self }
}

// PRODUCTION_REGISTRY
// PRODUCTION_ANCHOR

@main
private enum InspectorLifetimeTests {
    @MainActor
    static func drainReports() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    static func main() async {
        let registry = NBThemeInspectorRegistry.shared
        let window = UIWindow()
        window.bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let root = UIView()
        root.superview = window
        let anchors = (0..<100).map { _ in
            let anchor = NBThemeTargetAnchorView()
            anchor.superview = root
            anchor.metadata = NBThemePaintMetadata()
            anchor.didMoveToWindow()
            return anchor
        }
        for _ in 0..<100 {
            for anchor in anchors { anchor.layoutSubviews() }
        }
        await drainReports()
        assert(anchors.allSatisfy { $0.conversions == 0 },
               "Dormant icons must not sample geometry, including deferred callbacks")
        assert(registry.revision == 0, "Closed editor must not receive layout publications")

        let firstEditor = UUID(), secondEditor = UUID()
        registry.setInspectionActive(true, owner: firstEditor)
        assert(registry.isInspectionActive && registry.revision == 1)
        // No new anchor layout or view recreation: discovery must use LIVE
        // geometry, not the zero frame stored while the editor was closed.
        anchors[0].origin = CGPoint(x: 40, y: 100)
        let targets = registry.visibleTargets(in: window, within: root)
        assert(targets.count == 100)
        assert(targets.contains { $0.frame.origin == CGPoint(x: 40, y: 100) })
        assert(anchors.allSatisfy { $0.conversions == 1 })

        for _ in 0..<100 { anchors[0].layoutSubviews() }
        assert(anchors[0].conversions == 1, "Active layout reports should coalesce")
        await drainReports()
        assert(anchors[0].conversions == 2)
        let revision = registry.revision
        anchors[0].layoutSubviews()
        await drainReports()
        assert(registry.revision == revision, "Unchanged active geometry must not publish")

        registry.setInspectionActive(true, owner: secondEditor)
        registry.setInspectionActive(false, owner: firstEditor)
        assert(registry.isInspectionActive, "Closing one scene must retain another editor")
        // Closing during a pending report must suppress both conversion and
        // notifications, even though that callback was queued while editing.
        anchors[0].layoutSubviews()
        registry.setInspectionActive(false, owner: secondEditor)
        let conversions = anchors[0].conversions
        let closedRevision = registry.revision
        await drainReports()
        assert(anchors[0].conversions == conversions && registry.revision == closedRevision)

        anchors[0].elementID = "updated-while-closed"
        anchors[0].scheduleReport()
        anchors[1].superview = nil
        anchors[1].didMoveToWindow()
        anchors[2].isDismantled = true
        anchors[2].unregister()
        anchors[2].scheduleReport()
        await drainReports()
        assert(registry.revision == closedRevision)
        registry.setInspectionActive(true, owner: firstEditor)
        let reopened = registry.visibleTargets(in: window, within: root)
        assert(reopened.count == 98 && reopened.contains { $0.elementID == "updated-while-closed" })

        var temporary: NBThemeTargetAnchorView? = NBThemeTargetAnchorView()
        weak var weakAnchor = temporary
        temporary?.superview = root
        temporary?.metadata = NBThemePaintMetadata()
        temporary?.scheduleReport()
        await drainReports()
        assert(registry.visibleTargets(in: window, within: root).count == 99)
        temporary = nil
        assert(weakAnchor == nil, "Registry must not retain removed views")
        await drainReports()
        assert(registry.visibleTargets(in: window, within: root).count == 98)
        registry.setInspectionActive(false, owner: firstEditor)
        print("Theme inspector tests passed: 100 idle anchors, deferred geometry, immediate discovery, coalescing, scene ownership and cleanup.")
    }
}

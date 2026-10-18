import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// UIKit hierarchy doubles exercise the production pane installation method.
// They model view ordering/parentage and constraints, not glass rendering.
struct UIFont {
    enum TextStyle { case headline }
    var pointSize: CGFloat
    static func preferredFont(forTextStyle: TextStyle) -> UIFont { UIFont(pointSize: 20) }
}

extension NSAttributedString.Key {
    static let font = NSAttributedString.Key("font")
}

extension NSString {
    func size(withAttributes attributes: [NSAttributedString.Key: Any]) -> CGSize {
        let font = attributes[.font] as! UIFont
        return CGSize(width: CGFloat(length) * font.pointSize * 0.5, height: font.pointSize)
    }
}

@MainActor
class UIView {
    var subviews: [UIView] = []
    weak var superview: UIView?
    var isHidden = false
    var translatesAutoresizingMaskIntoConstraints = true
    var frame: CGRect
    var bounds: CGRect { CGRect(origin: .zero, size: frame.size) }
    init(frame: CGRect = .zero) { self.frame = frame }
    lazy var leadingAnchor = Anchor(owner: self, edge: "leading")
    lazy var trailingAnchor = Anchor(owner: self, edge: "trailing")
    lazy var topAnchor = Anchor(owner: self, edge: "top")
    lazy var bottomAnchor = Anchor(owner: self, edge: "bottom")

    func addSubview(_ child: UIView) {
        child.superview = self
        subviews.append(child)
    }

    func insertSubview(_ child: UIView, belowSubview sibling: UIView) {
        guard let index = subviews.firstIndex(where: { $0 === sibling }) else { fatalError("Invalid sibling") }
        child.superview = self
        subviews.insert(child, at: index)
    }
}

@MainActor
final class Anchor {
    unowned let owner: UIView
    let edge: String
    init(owner: UIView, edge: String) { self.owner = owner; self.edge = edge }
    func constraint(equalTo other: Anchor, constant: CGFloat = 0) -> NSLayoutConstraint {
        NSLayoutConstraint(self, other, constant: constant)
    }
}

@MainActor
final class NSLayoutConstraint {
    static var active: [NSLayoutConstraint] = []
    let first: Anchor
    let second: Anchor
    var constant: CGFloat
    init(_ first: Anchor, _ second: Anchor, constant: CGFloat) {
        self.first = first; self.second = second; self.constant = constant
    }
    static func activate(_ constraints: [NSLayoutConstraint]) {
        active += constraints
    }
    static func layout() {
        for constraint in active {
            let owner = constraint.first.owner
            let target = constraint.second.owner.frame
            switch constraint.first.edge {
            case "leading": owner.frame.origin.x = target.minX + constraint.constant
            case "trailing": owner.frame.size.width = target.maxX + constraint.constant - owner.frame.minX
            case "top": owner.frame.origin.y = target.minY + constraint.constant
            case "bottom": owner.frame.size.height = target.maxY + constraint.constant - owner.frame.minY
            default: fatalError("Unexpected anchor")
            }
        }
    }
}

@MainActor
final class UINavigationBar: UIView {
    var topItem: UINavigationItem? = UINavigationItem(title: "Settings")
    var titleTextAttributes: [NSAttributedString.Key: Any]?
}

struct UINavigationItem {
    var title: String?
}

@MainActor
private final class NavigationGlassPanelView: UIView {
    weak var navigationBar: UINavigationBar?
    var barConstraints: [NSLayoutConstraint] = []
}

@MainActor
final class NavigationBackdropProbe {
    var showGlass = true
    // PRODUCTION_UPDATE_BAR
    func apply(to bar: UINavigationBar) {
        updateBar(bar)
        NSLayoutConstraint.layout()
    }
}

@main
enum NavigationLayerTests {
    @MainActor
    static func main() {
        let container = UIView()
        let bar = UINavigationBar(frame: CGRect(x: 0, y: 59, width: 393, height: 44))
        let title = UIView()
        let edit = UIView()
        let plus = UIView()
        bar.addSubview(title)
        bar.addSubview(edit)
        bar.addSubview(plus)
        container.addSubview(bar)
        let probe = NavigationBackdropProbe()
        probe.apply(to: bar)
        assert(container.subviews.count == 2)
        let pane = container.subviews[0]
        assert(container.subviews[1] === bar, "Navigation controls must remain ABOVE the glass card")
        assert(pane.superview === container && pane.superview !== bar)
        assert(bar.frame.contains(pane.frame), "The capsule must not overlap the status bar or first row")
        assert(pane.frame.midX == bar.frame.midX && pane.frame.midY == bar.frame.midY)
        assert(pane.frame.width == 112 && pane.frame.height == 32,
               "The capsule must hug the title with 16pt horizontal and 6pt vertical padding")
        let leftButton = CGRect(x: 20, y: 59, width: 56, height: 44)
        let rightButton = CGRect(x: 329, y: 59, width: 44, height: 44)
        assert(!pane.frame.intersects(leftButton) && !pane.frame.intersects(rightButton))
        assert(bar.subviews.count == 3 && bar.subviews[0] === title && bar.subviews[1] === edit && bar.subviews[2] === plus,
               "Installing the pane must not reparent or cover native controls")
        assert(NSLayoutConstraint.active.count == 4)
        for constraint in NSLayoutConstraint.active {
            assert(constraint.first.owner === pane && constraint.second.owner === bar)
            assert(constraint.first.edge == constraint.second.edge)
        }
        assert(bar.translatesAutoresizingMaskIntoConstraints, "UIKit retains ownership of bar layout")
        probe.apply(to: bar)
        assert(container.subviews.count == 2 && NSLayoutConstraint.active.count == 4)
        bar.topItem?.title = "Appearance"
        probe.apply(to: bar)
        assert(pane.frame.width == 132, "Pushing a new title must resize the existing capsule")
        bar.titleTextAttributes = [.font: UIFont(pointSize: 28)]
        probe.apply(to: bar)
        assert(pane.frame.width == 172 && pane.frame.height == 40)
        bar.topItem?.title = "A much longer localized navigation title"
        bar.frame.size.width = 320
        probe.apply(to: bar)
        assert(pane.frame.width == 200 && pane.frame.midX == bar.frame.midX)
        probe.showGlass = false
        probe.apply(to: bar)
        assert(pane.isHidden && !title.isHidden && !edit.isHidden && !plus.isHidden)
        let detached = UINavigationBar()
        probe.apply(to: detached)
        assert(detached.subviews.isEmpty)
        probe.showGlass = true
        bar.topItem?.title = nil
        probe.apply(to: bar)
        assert(pane.isHidden)
        bar.topItem?.title = "Settings"
        bar.frame.size.height = 160
        probe.apply(to: bar)
        assert(pane.isHidden, "Expanded large titles must not get an oversized or misplaced pane")
        bar.frame.size.height = 44
        probe.apply(to: bar)
        assert(!pane.isHidden && bar.frame.contains(pane.frame))
        print("Navigation layer tests passed: compact centered title, no overlap, title/font/width changes, stable layers and glass toggle.")
    }
}

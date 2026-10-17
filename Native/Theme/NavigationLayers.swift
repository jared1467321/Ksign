import Foundation

// UIKit hierarchy doubles exercise the production pane installation method.
// They model view ordering/parentage and constraints, not glass rendering.
@MainActor
class UIView {
    var subviews: [UIView] = []
    weak var superview: UIView?
    var isHidden = false
    var translatesAutoresizingMaskIntoConstraints = true
    let frame: CGRect
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
    func constraint(equalTo other: Anchor) -> NSLayoutConstraint { NSLayoutConstraint(self, other) }
}

@MainActor
final class NSLayoutConstraint {
    static var active: [NSLayoutConstraint] = []
    let first: Anchor
    let second: Anchor
    init(_ first: Anchor, _ second: Anchor) { self.first = first; self.second = second }
    static func activate(_ constraints: [NSLayoutConstraint]) { active += constraints }
}

@MainActor
final class UINavigationBar: UIView {}

@MainActor
private final class NavigationGlassPanelView: UIView {
    weak var navigationBar: UINavigationBar?
}

@MainActor
final class NavigationBackdropProbe {
    var showGlass = true
    // PRODUCTION_UPDATE_BAR
    func apply(to bar: UINavigationBar) { updateBar(bar) }
}

@main
enum NavigationLayerTests {
    @MainActor
    static func main() {
        let container = UIView()
        let bar = UINavigationBar(frame: CGRect(x: 0, y: 59, width: 393, height: 160))
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
        probe.showGlass = false
        probe.apply(to: bar)
        assert(pane.isHidden && !title.isHidden && !edit.isHidden && !plus.isHidden)
        let detached = UINavigationBar()
        probe.apply(to: detached)
        assert(detached.subviews.isEmpty)
        print("Navigation layer tests passed: pane below title/buttons, stable parentage, layout ownership, no duplicates and glass toggle.")
    }
}

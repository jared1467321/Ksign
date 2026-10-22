import SwiftUI
import UIKit

/// Only the small foreground observes placement. Tracking must not invalidate
/// a List, its row builder, or the controls that own the label.
@available(iOS 17.0, tvOS 17.0, *)
@MainActor
final class NBAuroraTextPlacement: ObservableObject {
    @Published private(set) var bounds = CGRect(x: 0, y: 0, width: 1, height: 1)

    func receive(_ bounds: CGRect) {
        if self.bounds != bounds { self.bounds = bounds }
    }
}

@available(iOS 17.0, tvOS 17.0, *)
@MainActor
final class NBAuroraTextAttachment: ObservableObject {
    let placement = NBAuroraTextPlacement()
    let lease = NBAuroraInkLease()
    private var identity: NBAuroraShaderIdentity?

    func receive(bounds: CGRect?, reduceMotion: Bool) {
        if let bounds { placement.receive(bounds) }
        let visible = bounds != nil
        let identity = visible ? AuroraSession.shared.identity.shaderIdentity : nil
        guard lease.active != visible || lease.reduceMotion != reduceMotion
                || self.identity != identity else { return }
        self.identity = identity
        NBAuroraInkMap.shared.update(lease, active: visible, reduceMotion: reduceMotion)
    }
}

/// UIKit owns both the label and clipping coordinates. Polling attached views
/// once per shared display tick also covers layout that settles without a
/// SwiftUI geometry/appearance notification (including retained list cells).
@available(iOS 17.0, tvOS 17.0, *)
final class NBAuroraTextAnchorView: UIView {
    weak var attachment: NBAuroraTextAttachment?
    var reduceMotion = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            NBAuroraTextLayoutClock.shared.register(self)
        } else {
            NBAuroraTextLayoutClock.shared.remove(self)
        }
    }

    func sample() {
        attachment?.receive(bounds: inkBounds(), reduceMotion: reduceMotion)
    }

    func suspend() {
        attachment?.receive(bounds: nil, reduceMotion: reduceMotion)
    }

    private func inkBounds() -> CGRect? {
        guard let window, NBAuroraTextVisibility.usable(bounds),
              NBAuroraTextVisibility.usable(window.bounds) else { return nil }
        let frame = convert(bounds, to: window)
        guard NBAuroraTextVisibility.usable(frame) else { return nil }
        var visible = frame.intersection(window.bounds)
        var ancestor: UIView? = self
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01 else { return nil }
            if view.clipsToBounds {
                visible = visible.intersection(view.convert(view.bounds, to: window))
            }
            guard NBAuroraTextVisibility.usable(visible) else { return nil }
            if view === window { break }
            ancestor = view.superview
        }
        // Selection scales affect the window frame but not the shader's local
        // coordinates. Use both sizes so the ink stays aligned under scaling.
        let sx = frame.width / bounds.width, sy = frame.height / bounds.height
        return CGRect(x: (window.bounds.minX - frame.minX) / sx,
                      y: (window.bounds.minY - frame.minY) / sy,
                      width: window.bounds.width / sx, height: window.bounds.height / sy)
    }
}

@available(iOS 17.0, tvOS 17.0, *)
@MainActor
final class NBAuroraTextLayoutClock {
    static let shared = NBAuroraTextLayoutClock()
    private struct WeakAnchor {
        weak var value: NBAuroraTextAnchorView?
        weak var attachment: NBAuroraTextAttachment?
    }
    private var anchors: [ObjectIdentifier: WeakAnchor] = [:]
    private var displayLink: CADisplayLink?
    private var active = true

    func register(_ view: NBAuroraTextAnchorView) {
        guard view.window != nil else { return }
        anchors[ObjectIdentifier(view)] = WeakAnchor(value: view, attachment: view.attachment)
        startIfNeeded()
    }

    func remove(_ view: NBAuroraTextAnchorView) {
        anchors.removeValue(forKey: ObjectIdentifier(view))
        view.suspend()
        if anchors.isEmpty { stop() }
    }

    func setActive(_ active: Bool) {
        self.active = active
        if active {
            startIfNeeded()
        } else {
            stop()
            for entry in anchors.values { entry.value?.suspend() }
        }
    }

    fileprivate func tick() {
        guard active else { return }
        for (key, entry) in anchors {
            guard let view = entry.value else {
                entry.attachment?.receive(bounds: nil, reduceMotion: entry.attachment?.lease.reduceMotion ?? false)
                anchors.removeValue(forKey: key)
                continue
            }
            guard view.window != nil, view.attachment != nil else {
                view.suspend()
                anchors.removeValue(forKey: key)
                continue
            }
            view.sample()
        }
        if anchors.isEmpty { stop() }
    }

    private func startIfNeeded() {
        guard active, !anchors.isEmpty, displayLink == nil else { return }
        let target = NBAuroraTextLayoutTick(owner: self)
        let link = CADisplayLink(target: target, selector: #selector(NBAuroraTextLayoutTick.fire(_:)))
        link.preferredFramesPerSecond = NBAuroraInkMapFormat.framesPerSecond
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
}

@available(iOS 17.0, tvOS 17.0, *)
@MainActor
private final class NBAuroraTextLayoutTick: NSObject {
    weak var owner: NBAuroraTextLayoutClock?
    init(owner: NBAuroraTextLayoutClock) { self.owner = owner }
    @objc func fire(_ link: CADisplayLink) {
        guard let owner else { link.invalidate(); return }
        owner.tick()
    }
}

// MARK: - SwiftUI attachment

@available(iOS 17.0, tvOS 17.0, *)
struct NBAuroraTextAnchor: UIViewRepresentable {
    let attachment: NBAuroraTextAttachment
    let reduceMotion: Bool

    func makeUIView(context: Context) -> NBAuroraTextAnchorView {
        NBAuroraTextAnchorView(frame: .zero)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NBAuroraTextAnchorView,
                     context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    func updateUIView(_ view: NBAuroraTextAnchorView, context: Context) {
        view.attachment = attachment
        view.reduceMotion = reduceMotion
        // No observable writes inside a SwiftUI update. The next display tick
        // reads actual layout, even if this update precedes window attachment.
        NBAuroraTextLayoutClock.shared.register(view)
    }

    static func dismantleUIView(_ view: NBAuroraTextAnchorView, coordinator: ()) {
        NBAuroraTextLayoutClock.shared.remove(view)
        view.attachment = nil
    }
}

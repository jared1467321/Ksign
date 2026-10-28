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
    private(set) var isPresented = false
    fileprivate weak var anchor: NBAuroraTextAnchorView?
    private var identity: NBAuroraShaderIdentity?

    func setPresented(_ presented: Bool) {
        guard isPresented != presented else { return }
        isPresented = presented
        if !presented {
            // SwiftUI can retain both the scope and its native view after it
            // disappears. Release paint before any queued layout can run.
            receive(bounds: nil, reduceMotion: lease.reduceMotion)
        }
        anchor?.updateRegistration()
    }

    func receive(bounds: CGRect?, reduceMotion: Bool) {
        let bounds = isPresented ? bounds : nil
        if let bounds { placement.receive(bounds) }
        let visible = bounds != nil
        let identity = visible ? AuroraSession.shared.identity.shaderIdentity : nil
        guard lease.active != visible || lease.reduceMotion != reduceMotion
                || self.identity != identity else { return }
        self.identity = identity
        NBAuroraInkMap.shared.update(lease, active: visible, reduceMotion: reduceMotion)
    }
}

/// UIKit owns both the label and clipping coordinates. Cheap placement checks
/// follow movement at the ink cadence while the SwiftUI scope is presented.
/// Disappeared scopes unregister even if UIKit retains them in a window.
/// Stationary labels reuse their clipping result between periodic checks, which
/// also cover ancestor visibility changes without a SwiftUI geometry/appearance
/// notification (including retained cells).
@available(iOS 17.0, tvOS 17.0, *)
final class NBAuroraTextAnchorView: UIView {
    private(set) weak var attachment: NBAuroraTextAttachment?
    var reduceMotion = false

    var canTrack: Bool {
        window != nil && attachment?.isPresented == true && attachment?.anchor === self
    }

    private struct Geometry: Equatable {
        let window: ObjectIdentifier
        let bounds: CGRect
        let frame: CGRect
        let windowBounds: CGRect
    }
    private var lastGeometry: Geometry?
    private var lastVisibilityCheck: CFTimeInterval = -.infinity
    private var cachedInkBounds: CGRect?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        invalidateGeometry()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        invalidateGeometry()
        updateRegistration()
    }

    func updateRegistration() {
        if canTrack {
            NBAuroraTextLayoutClock.shared.register(self)
        } else {
            NBAuroraTextLayoutClock.shared.remove(self)
        }
    }

    func configure(attachment: NBAuroraTextAttachment, reduceMotion: Bool) {
        if self.attachment !== attachment {
            let previous = self.attachment
            if previous?.anchor === self { previous?.anchor = nil }
            self.attachment = attachment
            // Retire a replaced scope outside updateUIView. It may have been
            // rebound elsewhere before this callback; don't clear its new paint.
            if let previous {
                DispatchQueue.main.async { [weak previous] in
                    guard let previous, previous.anchor == nil else { return }
                    previous.receive(bounds: nil, reduceMotion: previous.lease.reduceMotion)
                }
            }
        }
        if let previousAnchor = attachment.anchor, previousAnchor !== self {
            previousAnchor.attachment = nil
            NBAuroraTextLayoutClock.shared.remove(previousAnchor)
        }
        attachment.anchor = self
        self.reduceMotion = reduceMotion
        invalidateGeometry()
        // Registration never samples/publishes inside a SwiftUI update.
        if canTrack {
            NBAuroraTextLayoutClock.shared.register(self)
        } else {
            NBAuroraTextLayoutClock.shared.remove(self, suspending: false)
            if attachment.lease.active {
                DispatchQueue.main.async { [weak self, weak attachment] in
                    guard let self, let attachment,
                          self.attachment === attachment, attachment.anchor === self,
                          !self.canTrack else { return }
                    self.suspend()
                }
            }
        }
    }

    func detach() {
        NBAuroraTextLayoutClock.shared.remove(self)
        if attachment?.anchor === self { attachment?.anchor = nil }
        attachment = nil
    }

    func sample(at time: CFTimeInterval) {
        guard canTrack else { suspend(); return }
        attachment?.receive(bounds: inkBounds(at: time), reduceMotion: reduceMotion)
    }

    func suspend() {
        invalidateGeometry()
        attachment?.receive(bounds: nil, reduceMotion: reduceMotion)
    }

    func invalidateGeometry() {
        lastGeometry = nil
        cachedInkBounds = nil
        lastVisibilityCheck = -.infinity
    }

    private func inkBounds(at time: CFTimeInterval) -> CGRect? {
        guard let window, NBAuroraTextVisibility.usable(bounds),
              NBAuroraTextVisibility.usable(window.bounds) else {
            invalidateGeometry()
            return nil
        }
        let frame = convert(bounds, to: window)
        guard NBAuroraTextVisibility.usable(frame) else {
            invalidateGeometry()
            return nil
        }
        let geometry = Geometry(window: ObjectIdentifier(window), bounds: bounds,
                                frame: frame, windowBounds: window.bounds)
        // A moving/scaling label needs fresh clipping immediately. Ancestors
        // can hide or resize around a stationary label, so never cache forever.
        if geometry == lastGeometry, time - lastVisibilityCheck < 0.25 {
            return cachedInkBounds
        }
        lastGeometry = geometry
        lastVisibilityCheck = time
        cachedInkBounds = visibleInkBounds(frame: frame, window: window)
        return cachedInkBounds
    }

    private func visibleInkBounds(frame: CGRect, window: UIWindow) -> CGRect? {
        var visible = frame.intersection(window.bounds)
        guard NBAuroraTextVisibility.usable(visible) else { return nil }
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
        guard view.canTrack else { return }
        anchors[ObjectIdentifier(view)] = WeakAnchor(value: view, attachment: view.attachment)
        startIfNeeded()
    }

    func remove(_ view: NBAuroraTextAnchorView, suspending: Bool = true) {
        anchors.removeValue(forKey: ObjectIdentifier(view))
        if suspending { view.suspend() }
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

    fileprivate func tick(at time: CFTimeInterval) {
        guard active else { return }
        for (key, entry) in anchors {
            guard let view = entry.value else {
                entry.attachment?.receive(bounds: nil, reduceMotion: entry.attachment?.lease.reduceMotion ?? false)
                anchors.removeValue(forKey: key)
                continue
            }
            guard view.canTrack else {
                view.suspend()
                anchors.removeValue(forKey: key)
                continue
            }
            view.sample(at: time)
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
        owner.tick(at: link.timestamp)
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
        view.configure(attachment: attachment, reduceMotion: reduceMotion)
    }

    static func dismantleUIView(_ view: NBAuroraTextAnchorView, coordinator: ()) {
        view.detach()
    }
}

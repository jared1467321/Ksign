//
//  NBThemeInspectorTarget.swift
//  NimbleViews
//
//  Registers real themed SwiftUI elements with the app-wide in-place theme
//  editor. Registration is presentation-independent: targets inside sheets,
//  full-screen covers, and nested hosting controllers report directly through
//  a process-wide registry instead of relying on SwiftUI preference propagation.
//

import SwiftUI
import UIKit
import NimbleExtensions

private struct NBInspectedThemeRoleKey: EnvironmentKey {
    static let defaultValue: NBThemeRole? = nil
}

public extension EnvironmentValues {
    /// Compatibility context used by existing screen-specific behavior.
    /// Discovery markers are owned exclusively by the global editor window.
    var nbInspectedThemeRole: NBThemeRole? {
        get { self[NBInspectedThemeRoleKey.self] }
        set { self[NBInspectedThemeRoleKey.self] = newValue }
    }
}

public struct NBThemeInspectorTargetFrame: Equatable {
    public let role: NBThemeRole
    public let frame: CGRect

    public init(role: NBThemeRole, frame: CGRect) {
        self.role = role
        self.frame = frame
    }
}

/// Registry used by the global theme-edit overlay. Targets remain registered
/// whether or not editing is currently active, which is what allows a sheet or
/// full-screen cover that was presented *before* Theme Edit begins to become
/// immediately selectable.
public final class NBThemeInspectorRegistry: ObservableObject, @unchecked Sendable {
    public static let shared = NBThemeInspectorRegistry()

    @Published public private(set) var revision: UInt64 = 0

    private final class Record {
        let id: UUID
        weak var view: UIView?
        var role: NBThemeRole
        var frame: CGRect

        init(id: UUID, view: UIView, role: NBThemeRole, frame: CGRect) {
            self.id = id
            self.view = view
            self.role = role
            self.frame = frame
        }
    }

    private var records: [UUID: Record] = [:]

    private init() {}

    fileprivate func register(id: UUID, view: UIView, role: NBThemeRole, frame: CGRect) {
        precondition(Thread.isMainThread)

        if let existing = records[id] {
            let changed = existing.view !== view || existing.role != role || existing.frame != frame
            existing.view = view
            existing.role = role
            existing.frame = frame
            if changed { revision &+= 1 }
        } else {
            records[id] = Record(id: id, view: view, role: role, frame: frame)
            revision &+= 1
        }
        purgeDeadRecordsIfNeeded()
    }

    fileprivate func unregister(id: UUID) {
        precondition(Thread.isMainThread)
        if records.removeValue(forKey: id) != nil {
            revision &+= 1
        }
    }

    /// Returns only targets belonging to the currently visible presentation
    /// root. When a sheet/full-screen cover is on top, covered targets from the
    /// presenting screen are intentionally excluded.
    public func visibleTargets(in window: UIWindow, within presentationRoot: UIView) -> [NBThemeInspectorTargetFrame] {
        precondition(Thread.isMainThread)

        purgeDeadRecordsIfNeeded()
        var result: [NBThemeInspectorTargetFrame] = []

        for record in records.values {
            guard let view = record.view,
                  view.window === window,
                  isVisible(view),
                  view === presentationRoot || view.isDescendant(of: presentationRoot) else { continue }

            let frame = Self.visibleFrame(of: view, in: window)
            guard frame.width > 0.5,
                  frame.height > 0.5,
                  frame.intersects(window.bounds) else { continue }

            result.append(.init(role: record.role, frame: frame))
        }

        return result
    }

    /// Clip against scroll containers as well as the window. Offscreen rows
    /// can remain mounted (and registered) while a list is being recycled.
    public static func visibleFrame(of view: UIView, in window: UIWindow) -> CGRect {
        guard view.window === window else { return .null }
        var frame = view.convert(view.bounds, to: window).intersection(window.bounds)
        var current: UIView? = view
        while let node = current {
            if node.isHidden || node.alpha <= 0.02 { return .null }
            if node.clipsToBounds {
                frame = frame.intersection(node.convert(node.bounds, to: window))
            }
            current = node.superview
        }
        return frame
    }

    private func isVisible(_ view: UIView) -> Bool {
        guard let window = view.window else { return false }
        return !Self.visibleFrame(of: view, in: window).isEmpty
    }

    private func purgeDeadRecordsIfNeeded() {
        let deadIDs = records.compactMap { key, value in value.view == nil ? key : nil }
        guard !deadIDs.isEmpty else { return }
        for id in deadIDs { records.removeValue(forKey: id) }
    }
}

public extension View {
    /// Marks a real UI element as a consumer of a semantic theme role.
    /// Geometry is reported in window coordinates so the global overlay can
    /// select it even when it lives inside a separately presented sheet.
    func nbThemeInspectorTarget(_ role: NBThemeRole) -> some View {
        modifier(NBThemeInspectorTargetModifier(role: role))
    }
}

private struct NBThemeInspectorTargetModifier: ViewModifier {
    @State private var targetID = UUID()
    let role: NBThemeRole

    func body(content: Content) -> some View {
        content
            .background {
                NBThemeTargetAnchor(id: targetID, role: role)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

private struct NBThemeTargetAnchor: UIViewRepresentable {
    let id: UUID
    let role: NBThemeRole

    func makeUIView(context: Context) -> NBThemeTargetAnchorView {
        let view = NBThemeTargetAnchorView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.targetID = id
        view.role = role
        return view
    }

    func updateUIView(_ uiView: NBThemeTargetAnchorView, context: Context) {
        uiView.targetID = id
        uiView.role = role
        uiView.scheduleReport()
    }

    static func dismantleUIView(_ uiView: NBThemeTargetAnchorView, coordinator: ()) {
        uiView.isDismantled = true
        uiView.unregister()
    }
}

private final class NBThemeTargetAnchorView: UIView {
    var targetID = UUID()
    var role: NBThemeRole = .background
    var isDismantled = false
    private var registeredID: UUID?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleReport()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleReport()
    }

    func scheduleReport() {
        DispatchQueue.main.async { [weak self] in
            self?.reportNow()
        }
    }

    func unregister() {
        if let registeredID {
            NBThemeInspectorRegistry.shared.unregister(id: registeredID)
            self.registeredID = nil
        }
    }

    private func reportNow() {
        guard !isDismantled, let window else {
            unregister()
            return
        }

        if let registeredID, registeredID != targetID {
            NBThemeInspectorRegistry.shared.unregister(id: registeredID)
        }
        registeredID = targetID

        NBThemeInspectorRegistry.shared.register(
            id: targetID,
            view: self,
            role: role,
            frame: convert(bounds, to: window)
        )
    }

    deinit {
        // UIKit dismantling normally unregisters synchronously. Avoid touching
        // the registry from deinit if teardown occurs off-main.
        if Thread.isMainThread, let registeredID {
            NBThemeInspectorRegistry.shared.unregister(id: registeredID)
        }
    }
}

//
//  NBThemeInspectorTarget.swift
//  NimbleExtensions
//
//  Registers real themed SwiftUI elements with the app-wide in-place theme
//  editor. This lives in NimbleExtensions so every existing NBHalloween call
//  site can opt into inspection without importing NimbleViews as well.
//

import SwiftUI
import UIKit
import NBThemePicking

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

// Logical ancestry comes from modifier composition, never registration timing.
public enum NBThemePaintKind: Int, Sendable {
    case canvas, background, fill, overlay, control, foreground, stroke, shadow, chrome
}

private struct NBThemePaintAncestryKey: EnvironmentKey {
    static let defaultValue: [UUID] = []
}
fileprivate struct NBThemePaintLayer: Equatable, Sendable {
    let group: UUID
    let id: UUID
    let order: Double
}
private struct NBThemePaintLayerKey: EnvironmentKey {
    static let defaultValue: [NBThemePaintLayer] = []
}
private struct NBThemePaintGroupKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}
private struct NBThemePaintOpacityKey: EnvironmentKey {
    static let defaultValue: Double = 1
}
@MainActor
fileprivate final class NBThemeClipRegion: ObservableObject {
    weak var view: UIView?
    var path: ((CGRect) -> Path)?

    func contains(_ point: CGPoint, in window: UIWindow) -> Bool {
        guard let view, view.window === window, let path else { return false }
        return path(view.bounds).contains(view.convert(point, from: window))
    }
}
private struct NBThemePaintClipsKey: EnvironmentKey {
    static let defaultValue: [NBThemeClipRegion] = []
}
private extension EnvironmentValues {
    var nbPaintOpacity: Double {
        get { self[NBThemePaintOpacityKey.self] }
        set { self[NBThemePaintOpacityKey.self] = newValue }
    }
    var nbPaintClips: [NBThemeClipRegion] {
        get { self[NBThemePaintClipsKey.self] }
        set { self[NBThemePaintClipsKey.self] = newValue }
    }
    var nbPaintAncestry: [UUID] {
        get { self[NBThemePaintAncestryKey.self] }
        set { self[NBThemePaintAncestryKey.self] = newValue }
    }
    var nbPaintLayer: [NBThemePaintLayer] {
        get { self[NBThemePaintLayerKey.self] }
        set { self[NBThemePaintLayerKey.self] = newValue }
    }
    var nbPaintGroup: UUID? {
        get { self[NBThemePaintGroupKey.self] }
        set { self[NBThemePaintGroupKey.self] = newValue }
    }
}

fileprivate struct NBThemePaintMetadata {
    var owner: UUID
    var ancestors: [UUID]
    var layer: [NBThemePaintLayer]
    var kind: NBThemePaintKind
    var alpha: Double
    var covers: Bool
    var editable: Bool
    var path: ((CGRect) -> Path)?
    var clips: [NBThemeClipRegion]
    var outset: CGFloat
}

/// Carries inspector ancestry across an explicit UIHostingConfiguration or
/// UIHostingController boundary. It contains no persistent element identities.
public struct NBThemeInspectorContext: Equatable {
    fileprivate var ancestors: [UUID] = []
    fileprivate var layers: [NBThemePaintLayer] = []
    fileprivate var opacity: Double = 1
    fileprivate var clips: [NBThemeClipRegion] = []
    public init() {}
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.ancestors == rhs.ancestors && lhs.layers == rhs.layers &&
        lhs.opacity == rhs.opacity &&
        lhs.clips.map(ObjectIdentifier.init) == rhs.clips.map(ObjectIdentifier.init)
    }
}

public extension EnvironmentValues {
    var nbThemeInspectorContext: NBThemeInspectorContext {
        get {
            var context = NBThemeInspectorContext()
            context.ancestors = nbPaintAncestry
            context.layers = nbPaintLayer
            context.opacity = nbPaintOpacity
            context.clips = nbPaintClips
            return context
        }
        set {
            nbPaintAncestry = newValue.ancestors
            nbPaintLayer = newValue.layers
            nbPaintOpacity = newValue.opacity
            nbPaintClips = newValue.clips
        }
    }
}

public struct NBThemeInspectorTargetFrame {
    public let role: NBThemeRole
    public let frame: CGRect
    /// Stable source identity for a locally-overridable themed element. A nil
    /// value means this is a semantic-role-only target.
    public let elementID: String?
    /// The color this exact target would render from the semantic role when it
    /// has no local override. Usually nil/direct-role; populated for transformed
    /// paints such as Accent at 16% opacity.
    public let initialColor: NBThemeColor?
    public var isEditable: Bool { metadata?.editable ?? true }
    fileprivate var metadata: NBThemePaintMetadata?
    fileprivate var pathContains: (@MainActor (CGPoint) -> Bool)?
    fileprivate var nativeKind: NBThemePaintKind = .control
    fileprivate var nativeAlpha: Double = 1

    public init(
        role: NBThemeRole,
        frame: CGRect,
        elementID: String? = nil,
        initialColor: NBThemeColor? = nil,
        kind: NBThemePaintKind = .control,
        alpha: Double = 1
    ) {
        self.role = role
        self.frame = frame
        self.elementID = elementID
        self.initialColor = initialColor
        self.nativeKind = kind
        self.nativeAlpha = alpha
    }
}

/// Registry used by the global theme-edit overlay. Targets remain registered
/// whether or not editing is currently active, which is what allows a sheet or
/// full-screen cover that was presented *before* Theme Edit begins to become
/// immediately selectable.
@MainActor
public final class NBThemeInspectorRegistry: ObservableObject {
    public static let shared = NBThemeInspectorRegistry()

    @Published public private(set) var revision: UInt64 = 0

    private final class Record {
        let id: UUID
        weak var view: UIView?
        var role: NBThemeRole
        var frame: CGRect
        var elementID: String?
        var initialColor: NBThemeColor?
        var metadata: NBThemePaintMetadata

        init(
            id: UUID,
            view: UIView,
            role: NBThemeRole,
            frame: CGRect,
            elementID: String?,
            initialColor: NBThemeColor?,
            metadata: NBThemePaintMetadata
        ) {
            self.id = id
            self.view = view
            self.role = role
            self.frame = frame
            self.elementID = elementID
            self.initialColor = initialColor
            self.metadata = metadata
        }
    }

    private var records: [UUID: Record] = [:]

    private init() {}

    fileprivate func register(
        id: UUID,
        view: UIView,
        role: NBThemeRole,
        frame: CGRect,
        elementID: String?,
        initialColor: NBThemeColor?,
        metadata: NBThemePaintMetadata
    ) {
        precondition(Thread.isMainThread)

        if let existing = records[id] {
            let changed = existing.view !== view ||
                existing.role != role ||
                existing.frame != frame ||
                existing.elementID != elementID ||
                existing.initialColor != initialColor ||
                existing.metadata.ancestors != metadata.ancestors ||
                existing.metadata.layer != metadata.layer ||
                existing.metadata.alpha != metadata.alpha
            existing.view = view
            existing.role = role
            existing.frame = frame
            existing.elementID = elementID
            existing.initialColor = initialColor
            existing.metadata = metadata
            if changed { revision &+= 1 }
        } else {
            records[id] = Record(
                id: id,
                view: view,
                role: role,
                frame: frame,
                elementID: elementID,
                initialColor: initialColor,
                metadata: metadata
            )
            revision &+= 1
        }
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
                  view === presentationRoot || view.isDescendant(of: presentationRoot) else { continue }

            let visibility = Self.visibility(of: view, in: window, outset: record.metadata.outset)
            let frame = visibility.frame
            guard frame.width > 0,
                  frame.height > 0,
                  frame.intersects(window.bounds) else { continue }

            var target = NBThemeInspectorTargetFrame(
                role: record.role,
                frame: frame,
                elementID: record.elementID,
                initialColor: record.initialColor
            )
            var metadata = record.metadata
            // SwiftUI may mirror the SAME opacity into UIView.alpha. Do not
            // square that opacity. This conservative minimum still rejects
            // hidden anchors and never treats translucent paint as opaque.
            metadata.alpha = min(metadata.alpha, visibility.alpha)
            target.metadata = metadata
            let path = metadata.path
            let clips = metadata.clips
                // Convert the TAP to local coordinates, not a clipped frame to
                // shape coordinates: clipping must not resize the shape path.
                target.pathContains = { [weak view, weak window] point in
                    guard let view, let window, view.window === window else { return false }
                    return (path?(view.bounds).contains(view.convert(point, from: window)) ?? true) &&
                        clips.allSatisfy { $0.contains(point, in: window) }
                }
            result.append(target)
        }

        return result
    }

    /// Pure production selector shared with the portable C regression suite.
    /// UIKit geometry and SwiftUI shape containment are sampled immediately
    /// before this call. No screenshot or sampled RGB participates in ownership.
    public static func pickTargets(_ targets: [NBThemeInspectorTargetFrame], at point: CGPoint) -> [NBThemeInspectorTargetFrame] {
        // Stable fallback between unrelated paints; UUID/registration order is
        // deliberately not a visual ordering signal.
        let sorted = targets.sorted {
            let a = "\($0.role.rawValue)|\($0.elementID ?? "")"
            let b = "\($1.role.rawValue)|\($1.elementID ?? "")"
            if a != b { return a < b }
            if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
            return $0.frame.minX < $1.frame.minX
        }
        var tokens: [UUID: UInt64] = [:]
        func token(_ id: UUID?) -> UInt64 {
            guard let id else { return 0 }
            if let value = tokens[id] { return value }
            let value = UInt64(tokens.count + 1)
            tokens[id] = value
            return value
        }
        var ancestry: [UInt64] = []
        var inputs: [NBPaintTarget] = []
        var layers: [NBPaintLayer] = []
        for target in sorted {
            let m = target.metadata
            var input = NBPaintTarget()
            input.x = Double(target.frame.minX)
            input.y = Double(target.frame.minY)
            input.width = Double(target.frame.width)
            input.height = Double(target.frame.height)
            input.alpha = m?.alpha ?? target.nativeAlpha
            input.owner = token(m?.owner)
            input.ancestors_offset = ancestry.count
            let parents = m?.ancestors ?? []
            input.ancestors_count = parents.count
            for parent in parents { ancestry.append(token(parent)) }
            input.layers_offset = layers.count
            let paintLayers = m?.layer ?? []
            input.layers_count = paintLayers.count
            for layer in paintLayers {
                var entry = NBPaintLayer()
                entry.group = token(layer.group)
                entry.id = token(layer.id)
                entry.order = layer.order
                layers.append(entry)
            }
            input.kind = Int32((m?.kind ?? target.nativeKind).rawValue)
            input.path_hit = (target.frame.contains(point) && (target.pathContains?(point) ?? true)) ? 1 : 0
            input.covers = (m?.covers ?? (target.nativeKind == .chrome)) ? 1 : 0
            inputs.append(input)
        }
        var indices = [Int](repeating: 0, count: inputs.count)
        let count = inputs.withUnsafeBufferPointer { ts in
            ancestry.withUnsafeBufferPointer { path in
                layers.withUnsafeBufferPointer { paintLayers in
                    indices.withUnsafeMutableBufferPointer { result in
                        nb_theme_pick(ts.baseAddress, ts.count, path.baseAddress, path.count,
                                      paintLayers.baseAddress, paintLayers.count,
                                      Double(point.x), Double(point.y), result.baseAddress)
                    }
                }
            }
        }
        return indices.prefix(count).map { sorted[$0] }.filter(\.isEditable)
    }

    /// Clip against scroll containers as well as the window. Offscreen rows
    /// can remain mounted (and registered) while a list is being recycled.
    public static func visibleFrame(of view: UIView, in window: UIWindow) -> CGRect {
        visibility(of: view, in: window).frame
    }

    private static func visibility(of view: UIView, in window: UIWindow, outset: CGFloat = 0) -> (frame: CGRect, alpha: Double) {
        guard view.window === window else { return (.null, 0) }
        let paintedBounds = view.bounds.insetBy(dx: -outset, dy: -outset)
        var frame = view.convert(paintedBounds, to: window).intersection(window.bounds)
        var current: UIView? = view
        var effectiveAlpha: CGFloat = 1
        while let node = current {
            effectiveAlpha *= node.alpha
            if node.isHidden || effectiveAlpha <= 0.02 { return (.null, 0) }
            if node.clipsToBounds {
                frame = frame.intersection(node.convert(node.bounds, to: window))
            }
            current = node.superview
        }
        return (frame, Double(effectiveAlpha))
    }

    private func purgeDeadRecordsIfNeeded() {
        let deadIDs = records.compactMap { key, value in value.view == nil ? key : nil }
        guard !deadIDs.isEmpty else { return }
        for id in deadIDs { records.removeValue(forKey: id) }
    }
}

// MARK: - Public theme-paint helpers

public extension View {
    /// A View overlay's front/back relation is known by construction. Unlike
    /// inspecting UIKit subview order, this survives SwiftUI render flattening.
    func nbThemeOverlay<Overlay: View>(alignment: Alignment = .center, @ViewBuilder content: () -> Overlay) -> some View {
        modifier(NBThemeLayeredPaintModifier(paint: content(), isOverlay: true, alignment: alignment))
    }

    func nbThemeOverlay<Overlay: View>(_ overlay: Overlay) -> some View {
        modifier(NBThemeLayeredPaintModifier(paint: overlay, isOverlay: true))
    }

    func nbThemeBackground<Background: View>(@ViewBuilder content: () -> Background) -> some View {
        modifier(NBThemeLayeredPaintModifier(paint: content(), isOverlay: false))
    }

    func nbThemeBackground<Background: View>(_ background: Background) -> some View {
        modifier(NBThemeLayeredPaintModifier(paint: background, isOverlay: false))
    }
    /// Declare a compositing group for sibling paint annotations. This adds no
    /// layout/container and does not change the view's rendering.
    func nbThemePaintGroup() -> some View { modifier(NBThemePaintGroupModifier()) }

    /// Mirrors zIndex AND supplies inspector order. Use only on actual sibling
    /// layers (or a known background/content/overlay relationship), in a group.
    /// Ordinary SwiftUI zIndex is intentionally not guessed from UIKit anchors.
    func nbThemePaintLayer(_ order: Double) -> some View {
        modifier(NBThemePaintLayerModifier(order: order))
    }

    /// Preserve whole-view opacity while explicitly exposing it to anchors;
    /// SwiftUI can apply opacity in its render graph without setting UIView.alpha.
    func nbThemeOpacity(_ value: Double) -> some View {
        modifier(NBThemePaintOpacityModifier(value: value))
    }

    func nbThemeClipShape<S: Shape>(_ shape: S) -> some View {
        modifier(NBThemeClipModifier(shape: shape))
    }

    /// An intentionally non-theme image/content surface. It blocks selection
    /// through its bounds without inventing a semantic role from artwork RGB.
    /// Only use for content meant to own the entire supplied region.
    func nbThemeContentSurface() -> some View {
        modifier(NBThemeInspectorTargetModifier(role: .background, elementID: nil,
            initialColor: nil, kind: .fill, editable: false))
    }
    /// Marks a real UI element as a consumer of a semantic theme role.
    /// Geometry is reported in window coordinates so the global overlay can
    /// select it even when it lives inside a separately presented sheet.
    func nbThemeInspectorTarget(_ role: NBThemeRole, kind: NBThemePaintKind = .foreground) -> some View {
        modifier(NBThemeInspectorTargetModifier(role: role, elementID: nil, initialColor: nil, kind: kind))
    }

    /// Applies a semantic foreground color and registers the exact call site as
    /// a locally-overridable target. Repeated runtime instances of the same
    /// source call site intentionally share one override unless elementID is
    /// supplied explicitly.
    func nbThemeForeground(
        _ role: NBThemeRole,
        opacity: Double = 1,
        elementID explicitElementID: String? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> some View {
        let elementID = explicitElementID ?? "\(fileID):\(line):\(column)"
        return modifier(NBThemeForegroundModifier(role: role, opacity: opacity, elementID: elementID))
    }

    /// Theme-backed background that can be edited either locally or by role.
    func nbThemeBackground(
        _ role: NBThemeRole,
        opacity: Double = 1,
        elementID explicitElementID: String? = nil,
        ignoresSafeAreaEdges edges: Edge.Set = [],
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> some View {
        let elementID = explicitElementID ?? nbThemeSourceID("background", fileID, line, column)
        return modifier(NBThemeBackgroundModifier(
            role: role,
            opacity: opacity,
            elementID: elementID,
            ignoresSafeAreaEdges: edges
        ))
    }

    /// Theme-backed shaped background, preserving the original shape geometry.
    func nbThemeBackground<S: Shape>(
        _ role: NBThemeRole,
        opacity: Double = 1,
        in shape: S,
        elementID explicitElementID: String? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> some View {
        let elementID = explicitElementID ?? nbThemeSourceID("background", fileID, line, column)
        return modifier(NBThemeShapedBackgroundModifier(
            role: role,
            opacity: opacity,
            elementID: elementID,
            shape: shape
        ))
    }

    /// Theme-backed overlay useful for separators and other flat paints.
    func nbThemeOverlay(
        _ role: NBThemeRole,
        opacity: Double = 1,
        elementID explicitElementID: String? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> some View {
        let elementID = explicitElementID ?? nbThemeSourceID("overlay", fileID, line, column)
        return modifier(NBThemeOverlayModifier(role: role, opacity: opacity, elementID: elementID))
    }

    /// Theme-backed control tint with exact-element override support.
    func nbThemeTint(
        _ role: NBThemeRole,
        opacity: Double = 1,
        elementID explicitElementID: String? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> some View {
        let elementID = explicitElementID ?? nbThemeSourceID("tint", fileID, line, column)
        return modifier(NBThemeTintModifier(role: role, opacity: opacity, elementID: elementID))
    }

    /// Same idea as nbThemeTint for older call sites that specifically rely on
    /// accentColor propagation semantics.
    func nbThemeAccentColor(
        _ role: NBThemeRole,
        opacity: Double = 1,
        elementID explicitElementID: String? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> some View {
        let elementID = explicitElementID ?? nbThemeSourceID("accentColor", fileID, line, column)
        return modifier(NBThemeAccentColorModifier(role: role, opacity: opacity, elementID: elementID))
    }

    /// Theme-backed shadow. The target frame is the source view's bounds; the
    /// shadow halo itself is intentionally not allowed to steal hit testing.
    func nbThemeShadow(
        _ role: NBThemeRole,
        opacity: Double = 1,
        radius: CGFloat,
        x: CGFloat = 0,
        y: CGFloat = 0,
        elementID explicitElementID: String? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> some View {
        let elementID = explicitElementID ?? nbThemeSourceID("shadow", fileID, line, column)
        return modifier(NBThemeShadowModifier(
            role: role,
            opacity: opacity,
            elementID: elementID,
            radius: radius,
            x: x,
            y: y
        ))
    }

    /// Apply to List/Form content, not the List itself: row traits must be
    /// inside the builder. Inherited text and separators are role-wide targets;
    /// explicit foreground helpers on child labels still take precedence.
    func nbThemeRow(
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> some View {
        modifier(NBThemeRowModifier(elementID: nbThemeSourceID("row", fileID, line, column)))
    }

    /// Standardizes raw SwiftUI List/Form canvases. System scroll backgrounds
    /// are hidden so the role really paints the visible pixels; the target is
    /// exact-editable, and unannotated primary/secondary list text plus row
    /// separators follow the theme as well.
    func nbThemeCanvas(
        _ role: NBThemeRole = .background,
        elementID explicitElementID: String? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> some View {
        let elementID = explicitElementID ?? nbThemeSourceID("canvas", fileID, line, column)
        return modifier(NBThemeCanvasModifier(role: role, elementID: elementID))
    }
}

/// A theme-backed Color-like view for places that require a standalone View
/// (for example listRowBackground or a full-screen scrim).
public struct NBThemePaint: View {
    @ObservedObject private var themes = NBThemeManager.shared

    private let role: NBThemeRole
    private let opacity: Double
    private let elementID: String

    public init(
        _ role: NBThemeRole,
        opacity: Double = 1,
        elementID explicitElementID: String? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) {
        self.role = role
        self.opacity = opacity
        self.elementID = explicitElementID ?? nbThemeSourceID("paint", fileID, line, column)
    }

    public var body: some View {
        let semantic = nbThemeSemanticColor(themes, role, opacity)
        let resolved = nbThemeResolvedElementColor(themes, role, elementID, opacity)
        resolved.color
            .modifier(NBThemeInspectorTargetModifier(
                role: role,
                elementID: elementID,
                initialColor: semantic,
                kind: .fill, alpha: resolved.alpha
            ))
    }
}

public extension Shape {
    func nbThemeFill(
        _ role: NBThemeRole,
        opacity: Double = 1,
        elementID explicitElementID: String? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> some View {
        NBThemeFilledShape(
            shape: self,
            role: role,
            opacity: opacity,
            elementID: explicitElementID ?? nbThemeSourceID("fill", fileID, line, column)
        )
    }

    func nbThemeStroke(
        _ role: NBThemeRole,
        opacity: Double = 1,
        lineWidth: CGFloat = 1,
        elementID explicitElementID: String? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> some View {
        NBThemeStrokedShape(
            shape: self,
            role: role,
            opacity: opacity,
            elementID: explicitElementID ?? nbThemeSourceID("stroke", fileID, line, column),
            stroke: .lineWidth(lineWidth)
        )
    }

    func nbThemeStroke(
        _ role: NBThemeRole,
        opacity: Double = 1,
        style: StrokeStyle,
        elementID explicitElementID: String? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> some View {
        NBThemeStrokedShape(
            shape: self,
            role: role,
            opacity: opacity,
            elementID: explicitElementID ?? nbThemeSourceID("stroke", fileID, line, column),
            stroke: .style(style)
        )
    }
}

public extension InsettableShape {
    func nbThemeStrokeBorder(
        _ role: NBThemeRole,
        opacity: Double = 1,
        lineWidth: CGFloat = 1,
        elementID explicitElementID: String? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> some View {
        NBThemeStrokeBorderShape(
            shape: self,
            role: role,
            opacity: opacity,
            elementID: explicitElementID ?? nbThemeSourceID("strokeBorder", fileID, line, column),
            lineWidth: lineWidth
        )
    }
}

// MARK: - Paint implementation

private func nbThemeSourceID(
    _ kind: String,
    _ fileID: StaticString,
    _ line: UInt,
    _ column: UInt
) -> String {
    "\(kind)|\(fileID):\(line):\(column)"
}

private func nbThemeSemanticColor(
    _ themes: NBThemeManager,
    _ role: NBThemeRole,
    _ opacity: Double
) -> NBThemeColor {
    var color = themes.activeColor(for: role)
    color.alpha *= min(1, max(0, opacity))
    return color
}

private func nbThemeResolvedElementColor(
    _ themes: NBThemeManager,
    _ role: NBThemeRole,
    _ elementID: String,
    _ opacity: Double
) -> NBThemeColor {
    // A local override/preview is the literal final color for this element. The
    // fixed semantic opacity is only the fallback transformation when this
    // element still follows its role.
    if themes.hasElementOverride(elementID) ||
        themes.isPreviewing(role, elementID: elementID, in: themes.selectedThemeID) {
        return themes.activeColor(for: role, elementID: elementID)
    }
    return nbThemeSemanticColor(themes, role, opacity)
}

private struct NBThemeForegroundModifier: ViewModifier {
    @ObservedObject private var themes = NBThemeManager.shared
    let role: NBThemeRole
    let opacity: Double
    let elementID: String

    func body(content: Content) -> some View {
        let _ = themes.previewRevision
        let semantic = nbThemeSemanticColor(themes, role, opacity)
        let resolved = nbThemeResolvedElementColor(themes, role, elementID, opacity)
        content
            .foregroundStyle(resolved.color)
            .modifier(NBThemeInspectorTargetModifier(
                role: role,
                elementID: elementID,
                initialColor: semantic,
                kind: .foreground, alpha: resolved.alpha
            ))
    }
}

private struct NBThemeBackgroundModifier: ViewModifier {
    @ObservedObject private var themes = NBThemeManager.shared
    @Environment(\.nbPaintAncestry) private var ancestors
    @State private var ownerID = UUID()
    let role: NBThemeRole
    let opacity: Double
    let elementID: String
    let ignoresSafeAreaEdges: Edge.Set

    func body(content: Content) -> some View {
        let _ = themes.previewRevision
        let semantic = nbThemeSemanticColor(themes, role, opacity)
        let resolved = nbThemeResolvedElementColor(themes, role, elementID, opacity)
        content
            .environment(\.nbPaintAncestry, ancestors + [ownerID])
            .background {
                resolved.color
                    .modifier(NBThemeInspectorTargetModifier(
                        role: role,
                        elementID: elementID,
                        initialColor: semantic,
                        kind: .background, alpha: resolved.alpha, scopeID: ownerID
                    ))
                    .ignoresSafeArea(edges: ignoresSafeAreaEdges)
            }
    }
}

private struct NBThemeShapedBackgroundModifier<S: Shape>: ViewModifier {
    @ObservedObject private var themes = NBThemeManager.shared
    @Environment(\.nbPaintAncestry) private var ancestors
    @State private var ownerID = UUID()
    let role: NBThemeRole
    let opacity: Double
    let elementID: String
    let shape: S

    func body(content: Content) -> some View {
        let _ = themes.previewRevision
        let semantic = nbThemeSemanticColor(themes, role, opacity)
        let resolved = nbThemeResolvedElementColor(themes, role, elementID, opacity)
        content
            .environment(\.nbPaintAncestry, ancestors + [ownerID])
            .background(resolved.color, in: shape)
            .modifier(NBThemeInspectorTargetModifier(
                role: role,
                elementID: elementID,
                initialColor: semantic,
                kind: .background, alpha: resolved.alpha, scopeID: ownerID, path: { [shape] in shape.path(in: $0) }
            ))
    }
}

private struct NBThemeOverlayModifier: ViewModifier {
    @ObservedObject private var themes = NBThemeManager.shared
    let role: NBThemeRole
    let opacity: Double
    let elementID: String

    func body(content: Content) -> some View {
        let _ = themes.previewRevision
        let semantic = nbThemeSemanticColor(themes, role, opacity)
        let resolved = nbThemeResolvedElementColor(themes, role, elementID, opacity)
        content
            .overlay(resolved.color)
            .modifier(NBThemeInspectorTargetModifier(
                role: role,
                elementID: elementID,
                initialColor: semantic,
                kind: .overlay, alpha: resolved.alpha
            ))
    }
}

private struct NBThemeTintModifier: ViewModifier {
    @ObservedObject private var themes = NBThemeManager.shared
    let role: NBThemeRole
    let opacity: Double
    let elementID: String

    func body(content: Content) -> some View {
        let _ = themes.previewRevision
        let semantic = nbThemeSemanticColor(themes, role, opacity)
        let resolved = nbThemeResolvedElementColor(themes, role, elementID, opacity)
        content
            .tint(resolved.color)
            .modifier(NBThemeInspectorTargetModifier(
                role: role,
                elementID: elementID,
                initialColor: semantic,
                kind: .control, alpha: resolved.alpha
            ))
    }
}

private struct NBThemeAccentColorModifier: ViewModifier {
    @ObservedObject private var themes = NBThemeManager.shared
    let role: NBThemeRole
    let opacity: Double
    let elementID: String

    func body(content: Content) -> some View {
        let _ = themes.previewRevision
        let semantic = nbThemeSemanticColor(themes, role, opacity)
        let resolved = nbThemeResolvedElementColor(themes, role, elementID, opacity)
        content
            .accentColor(resolved.color)
            .modifier(NBThemeInspectorTargetModifier(
                role: role,
                elementID: elementID,
                initialColor: semantic,
                kind: .control, alpha: resolved.alpha
            ))
    }
}

private struct NBThemeShadowModifier: ViewModifier {
    @ObservedObject private var themes = NBThemeManager.shared
    let role: NBThemeRole
    let opacity: Double
    let elementID: String
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat

    func body(content: Content) -> some View {
        let _ = themes.previewRevision
        let semantic = nbThemeSemanticColor(themes, role, opacity)
        let resolved = nbThemeResolvedElementColor(themes, role, elementID, opacity)
        content
            .shadow(color: resolved.color, radius: radius, x: x, y: y)
            .modifier(NBThemeInspectorTargetModifier(
                role: role,
                elementID: elementID,
                initialColor: semantic,
                kind: .shadow, alpha: resolved.alpha
            ))
    }
}

private struct NBThemeRowModifier: ViewModifier {
    @ObservedObject private var themes = NBThemeManager.shared
    let elementID: String

    func body(content: Content) -> some View {
        content
            .foregroundStyle(themes.activeColor(for: .text).color, themes.activeColor(for: .textSecondary).color)
            .listRowSeparatorTint(themes.activeColor(for: .separator).color)
            .listRowBackground(NBThemePaint(.elevated, elementID: elementID))
            .nbThemeInspectorTarget(.text)
            .nbThemeInspectorTarget(.textSecondary)
            .nbThemeInspectorTarget(.separator)
    }
}

private struct NBThemeCanvasModifier: ViewModifier {
    @ObservedObject private var themes = NBThemeManager.shared
    @Environment(\.nbPaintAncestry) private var ancestors
    @State private var ownerID = UUID()
    let role: NBThemeRole
    let elementID: String

    func body(content: Content) -> some View {
        let _ = themes.previewRevision
        let primary = themes.activeColor(for: .text).color
        let secondary = themes.activeColor(for: .textSecondary).color
        let separator = themes.activeColor(for: .separator).color
        let semantic = themes.activeColor(for: role)
        let resolved = nbThemeResolvedElementColor(themes, role, elementID, 1)

        content
            .environment(\.nbPaintAncestry, ancestors + [ownerID])
            .foregroundStyle(primary, secondary)
            .listRowSeparatorTint(separator)
            .scrollContentBackground(.hidden)
            .background {
                // Register the paint's bounds, including its safe-area extent,
                // rather than the smaller content rectangle above it.
                resolved.color
                    .modifier(NBThemeInspectorTargetModifier(
                        role: role,
                        elementID: elementID,
                        initialColor: semantic,
                        kind: .canvas, alpha: resolved.alpha, scopeID: ownerID
                    ))
                    .ignoresSafeArea()
            }
    }
}

private struct NBThemeFilledShape<S: Shape>: View {
    @ObservedObject private var themes = NBThemeManager.shared
    let shape: S
    let role: NBThemeRole
    let opacity: Double
    let elementID: String

    var body: some View {
        let _ = themes.previewRevision
        let semantic = nbThemeSemanticColor(themes, role, opacity)
        let resolved = nbThemeResolvedElementColor(themes, role, elementID, opacity)
        shape
            .fill(resolved.color)
            .modifier(NBThemeInspectorTargetModifier(
                role: role,
                elementID: elementID,
                initialColor: semantic,
                kind: .fill, alpha: resolved.alpha, path: { [shape] in shape.path(in: $0) }
            ))
    }
}

private enum NBThemeStrokeSpec {
    case lineWidth(CGFloat)
    case style(StrokeStyle)
}

private struct NBThemeStrokedShape<S: Shape>: View {
    @ObservedObject private var themes = NBThemeManager.shared
    let shape: S
    let role: NBThemeRole
    let opacity: Double
    let elementID: String
    let stroke: NBThemeStrokeSpec

    @ViewBuilder
    var body: some View {
        let _ = themes.previewRevision
        let semantic = nbThemeSemanticColor(themes, role, opacity)
        let resolved = nbThemeResolvedElementColor(themes, role, elementID, opacity)
        switch stroke {
        case .lineWidth(let lineWidth):
            shape
                .stroke(resolved.color, lineWidth: lineWidth)
                .modifier(NBThemeInspectorTargetModifier(
                    role: role,
                    elementID: elementID,
                    initialColor: semantic,
                    kind: .stroke, alpha: resolved.alpha, path: { [shape, lineWidth] in shape.path(in: $0).strokedPath(StrokeStyle(lineWidth: lineWidth)) }, outset: lineWidth / 2
                ))
        case .style(let style):
            shape
                .stroke(resolved.color, style: style)
                .modifier(NBThemeInspectorTargetModifier(
                    role: role,
                    elementID: elementID,
                    initialColor: semantic,
                    kind: .stroke, alpha: resolved.alpha, path: { [shape] in shape.path(in: $0).strokedPath(style) }, outset: style.lineWidth / 2
                ))
        }
    }
}

private struct NBThemeStrokeBorderShape<S: InsettableShape>: View {
    @ObservedObject private var themes = NBThemeManager.shared
    let shape: S
    let role: NBThemeRole
    let opacity: Double
    let elementID: String
    let lineWidth: CGFloat

    var body: some View {
        let _ = themes.previewRevision
        let semantic = nbThemeSemanticColor(themes, role, opacity)
        let resolved = nbThemeResolvedElementColor(themes, role, elementID, opacity)
        shape
            .strokeBorder(resolved.color, lineWidth: lineWidth)
            .modifier(NBThemeInspectorTargetModifier(
                role: role,
                elementID: elementID,
                initialColor: semantic,
                kind: .stroke, alpha: resolved.alpha, path: { [shape, lineWidth] in shape.inset(by: lineWidth / 2).path(in: $0).strokedPath(StrokeStyle(lineWidth: lineWidth)) }
            ))
    }
}

// MARK: - Geometry registration

private struct NBThemeInspectorTargetModifier: ViewModifier {
    @State private var targetID = UUID()
    @Environment(\.nbPaintAncestry) private var ancestors
    @Environment(\.nbPaintLayer) private var layer
    @Environment(\.nbPaintOpacity) private var inheritedOpacity
    @Environment(\.nbPaintClips) private var clips
    let role: NBThemeRole
    let elementID: String?
    let initialColor: NBThemeColor?

    var kind: NBThemePaintKind = .foreground
    var alpha: Double = 1
    var scopeID: UUID? = nil
    var path: ((CGRect) -> Path)? = nil
    var editable: Bool = true
    var outset: CGFloat = 0

    func body(content: Content) -> some View {
        let owner = scopeID ?? targetID
        let parents = ancestors.filter { $0 != owner }
        return content
            .environment(\.nbPaintAncestry, parents + [owner])
            .background {
                NBThemeTargetAnchor(
                    id: targetID,
                    role: role,
                    elementID: elementID,
                    initialColor: initialColor,
                    metadata: NBThemePaintMetadata(
                        owner: owner, ancestors: parents, layer: layer, kind: kind,
                        alpha: alpha * inheritedOpacity,
                        covers: [.canvas, .background, .fill, .overlay, .stroke].contains(kind),
                        editable: editable, path: path, clips: clips, outset: outset
                    )
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

private struct NBThemeTargetAnchor: UIViewRepresentable {
    let id: UUID
    let role: NBThemeRole
    let elementID: String?
    let initialColor: NBThemeColor?
    let metadata: NBThemePaintMetadata

    func makeUIView(context: Context) -> NBThemeTargetAnchorView {
        let view = NBThemeTargetAnchorView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.targetID = id
        view.role = role
        view.elementID = elementID
        view.initialColor = initialColor
        view.metadata = metadata
        return view
    }

    func updateUIView(_ uiView: NBThemeTargetAnchorView, context: Context) {
        uiView.targetID = id
        uiView.role = role
        uiView.elementID = elementID
        uiView.initialColor = initialColor
        uiView.metadata = metadata
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
    var elementID: String?
    var initialColor: NBThemeColor?
    var metadata: NBThemePaintMetadata?
    private var reportScheduled = false
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
        guard !reportScheduled, !isDismantled else { return }
        reportScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.reportScheduled = false
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
        guard !isDismantled, let window, let metadata else {
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
            frame: convert(bounds, to: window),
            elementID: elementID,
            initialColor: initialColor,
            metadata: metadata
        )
    }

    deinit {
        // Dismantle handles ordinary removal synchronously. This fallback can
        // run on any thread; capture only the Sendable ID, never the dead view.
        if let registeredID {
            DispatchQueue.main.async {
                NBThemeInspectorRegistry.shared.unregister(id: registeredID)
            }
        }
    }
}

private struct NBThemePaintGroupModifier: ViewModifier {
    @State private var groupID = UUID()
    func body(content: Content) -> some View {
        content.environment(\.nbPaintGroup, groupID)
    }
}

private struct NBThemeLayeredPaintModifier<Paint: View>: ViewModifier {
    @Environment(\.nbPaintLayer) private var layers
    @State private var groupID = UUID()
    @State private var contentID = UUID()
    @State private var paintID = UUID()
    let paint: Paint
    let isOverlay: Bool
    var alignment: Alignment = .center

    @ViewBuilder
    func body(content: Content) -> some View {
        let contentLayers = layers + [NBThemePaintLayer(group: groupID, id: contentID, order: isOverlay ? 0 : 1)]
        let paintLayers = layers + [NBThemePaintLayer(group: groupID, id: paintID, order: isOverlay ? 1 : 0)]
        if isOverlay {
            content.environment(\.nbPaintLayer, contentLayers)
                .overlay(alignment: alignment) { paint.environment(\.nbPaintLayer, paintLayers) }
        } else {
            content.environment(\.nbPaintLayer, contentLayers)
                .background { paint.environment(\.nbPaintLayer, paintLayers) }
        }
    }
}

private struct NBThemePaintLayerModifier: ViewModifier {
    @Environment(\.nbPaintGroup) private var group
    @Environment(\.nbPaintLayer) private var layers
    @State private var layerID = UUID()
    let order: Double
    func body(content: Content) -> some View {
        content
            .zIndex(order)
            .environment(\.nbPaintLayer, layers + (group.map { [NBThemePaintLayer(group: $0, id: layerID, order: order)] } ?? []))
    }
}

private struct NBThemePaintOpacityModifier: ViewModifier {
    @Environment(\.nbPaintOpacity) private var inherited
    let value: Double
    func body(content: Content) -> some View {
        content.opacity(value)
            .environment(\.nbPaintOpacity, inherited * min(1, max(0, value)))
    }
}

private struct NBThemeClipModifier<S: Shape>: ViewModifier {
    @Environment(\.nbPaintClips) private var clips
    @StateObject private var region = NBThemeClipRegion()
    let shape: S
    func body(content: Content) -> some View {
        content
            .environment(\.nbPaintClips, clips + [region])
            .clipShape(shape)
            .background {
                NBThemeClipAnchor(region: region, path: { [shape] in shape.path(in: $0) })
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

private struct NBThemeClipAnchor: UIViewRepresentable {
    let region: NBThemeClipRegion
    let path: (CGRect) -> Path
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        region.view = view
        region.path = path
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        region.view = view
        region.path = path
    }
}

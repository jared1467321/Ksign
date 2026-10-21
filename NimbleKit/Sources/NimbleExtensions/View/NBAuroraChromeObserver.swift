import SwiftUI
import UIKit

struct NBAuroraNativeGlyph: Identifiable, Equatable {
    let source: NBAuroraChromeSource
    let image: UIImage
    let frame: CGRect
    let visibleFrame: CGRect
    let ancestorOpacity: Double
    let role: NBThemeRole
    let elementID: String?
    var id: ObjectIdentifier { ObjectIdentifier(source) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source === rhs.source && lhs.image === rhs.image && lhs.frame == rhs.frame
            && lhs.visibleFrame == rhs.visibleFrame && lhs.ancestorOpacity == rhs.ancestorOpacity
            && lhs.role == rhs.role && lhs.elementID == rhs.elementID
    }
}

/// Captures only a glyph's alpha, never a screenshot of the screen/backdrop.
/// A transparent layer mask suppresses native label/icon paint without changing
/// UIView visibility, layout, hit testing, accessibility, or the control's data.
@MainActor
final class NBAuroraChromeSource {
    weak var view: UIView?
    var role: NBThemeRole
    var elementID: String?
    private let emptyMask = CALayer()
    private var originalMask: CALayer?
    private var originalTextColor: UIColor?
    private var originalPlaceholder: NSAttributedString?
    private var placeholderString: String?
    private var hidden = false
    private var active = true
    private var fingerprint = ""
    private var image: UIImage?
    private var lastCapture: CFTimeInterval = -.infinity
    private static let placeholderMarker = NSAttributedString.Key("NimbleKit.auroraHiddenPlaceholder")

    init(view: UIView, role: NBThemeRole, elementID: String?) {
        self.view = view
        self.role = role
        self.elementID = elementID
    }

    func hide() {
        guard active, let view else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let field = view as? UISearchTextField {
            if !hidden || field.textColor != .clear { originalTextColor = field.textColor }
            if !Self.isHiddenPlaceholder(field.attributedPlaceholder) {
                originalPlaceholder = field.attributedPlaceholder
                placeholderString = field.placeholder
            }
            field.textColor = .clear
            if let text = field.placeholder, !text.isEmpty {
                let placeholder = NSMutableAttributedString(
                    attributedString: field.attributedPlaceholder ?? NSAttributedString(string: text)
                )
                placeholder.addAttributes([.foregroundColor: UIColor.clear, Self.placeholderMarker: true],
                                          range: NSRange(location: 0, length: placeholder.length))
                field.attributedPlaceholder = placeholder
            }
        } else {
            if view.layer.mask !== emptyMask { originalMask = view.layer.mask }
            view.layer.mask = emptyMask
        }
        hidden = true
    }

    func restore() {
        guard hidden, let view else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let field = view as? UISearchTextField {
            // Appearance/theme refreshes may have installed a new color while
            // this source was hidden. Never overwrite that external change.
            if field.textColor == .clear { field.textColor = originalTextColor }
            if Self.isHiddenPlaceholder(field.attributedPlaceholder) {
                if let originalPlaceholder {
                    field.attributedPlaceholder = originalPlaceholder
                } else {
                    field.placeholder = placeholderString
                }
            }
        } else if view.layer.mask === emptyMask {
            view.layer.mask = originalMask
        }
        hidden = false
    }

    func retire() {
        restore()
        active = false
    }

    func glyphImage() -> UIImage? {
        guard let view, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let signature: String
        if let field = view as? UISearchTextField {
            let selection = field.selectedTextRange.map {
                "\(field.offset(from: field.beginningOfDocument, to: $0.start)):\(field.offset(from: field.beginningOfDocument, to: $0.end))"
            } ?? ""
            let placeholder = Self.isHiddenPlaceholder(field.attributedPlaceholder)
                ? originalPlaceholder : field.attributedPlaceholder
            let color = field.textColor == .clear ? originalTextColor : field.textColor
            signature = [field.text ?? "", field.placeholder ?? "", field.font?.description ?? "",
                         String(field.isEditing), String(field.textAlignment.rawValue), selection,
                         String(field.attributedText?.hash ?? 0), String(placeholder?.hash ?? 0),
                         color?.description ?? ""].joined(separator: "|")
        } else if let label = view as? UILabel {
            signature = [label.text ?? "", String(label.attributedText?.hash ?? 0), label.font.description,
                         label.textColor.description, String(label.textAlignment.rawValue),
                         String(label.numberOfLines)].joined(separator: "|")
        } else if let icon = view as? UIImageView {
            signature = [String(icon.image?.hash ?? 0), String(icon.highlightedImage?.hash ?? 0),
                         String(icon.isHighlighted), icon.tintColor.description].joined(separator: "|")
        } else {
            return nil
        }
        let key = "\(signature)|\(view.bounds)|\(view.window?.screen.scale ?? 1)"
        let now = CACurrentMediaTime()
        guard key != fingerprint || (image == nil && now - lastCapture >= 0.25) else { return image }

        let wasHidden = hidden
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        restore()
        view.layoutIfNeeded()
        view.layer.displayIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = view.window?.screen.scale ?? 1
        format.opaque = false
        let captured = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            if let field = view as? UISearchTextField {
                drawSearchGlyph(field, in: context.cgContext)
            } else {
                view.layer.render(in: context.cgContext)
            }
        }
        image = Self.hasGlyphPixels(captured) ? captured : nil
        if wasHidden { hide() }
        CATransaction.commit()
        fingerprint = key
        lastCapture = now
        return image
    }

    private static func hasGlyphPixels(_ image: UIImage) -> Bool {
        guard let image = image.cgImage else { return false }
        // A tiny alpha reduction is enough to reject empty native captures.
        // Never suppress a native glyph unless the overlay has paint for it.
        var pixels = [UInt8](repeating: 0, count: 16 * 8 * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 16, height: 8,
                                          bitsPerComponent: 8, bytesPerRow: 16 * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 8))
            return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 }
        }
    }

    private func drawSearchGlyph(_ field: UISearchTextField, in context: CGContext) {
        // Draw only the text with its native attributes. UITextInput supplies
        // its actual text position, including horizontal scrolling while the
        // cursor moves. Material, magnifier, caret and selection stay native.
        let placeholder = (field.text ?? "").isEmpty
        let value = placeholder ? field.placeholder ?? "" : field.text ?? ""
        guard !value.isEmpty else { return }
        var attributes = field.defaultTextAttributes
        attributes[.font] = field.font ?? UIFont.systemFont(ofSize: UIFont.systemFontSize)
        attributes[.foregroundColor] = placeholder ? UIColor.placeholderText : field.textColor ?? .label
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = field.textAlignment
        paragraph.lineBreakMode = .byClipping
        attributes[.paragraphStyle] = paragraph
        let text = NSMutableAttributedString(string: value, attributes: attributes)
        let native = placeholder ? field.attributedPlaceholder : field.attributedText
        if let native, native.string == value {
            native.enumerateAttributes(in: NSRange(location: 0, length: native.length)) { attributes, range, _ in
                text.addAttributes(attributes, range: range)
            }
        }

        let clip = placeholder ? field.placeholderRect(forBounds: field.bounds)
            : field.isEditing ? field.editingRect(forBounds: field.bounds) : field.textRect(forBounds: field.bounds)
        var rect = clip
        if !placeholder,
           let range = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument) {
            let nativeRect = field.firstRect(for: range)
            if !nativeRect.isNull, !nativeRect.isInfinite, !nativeRect.isEmpty {
                rect = field.convert(nativeRect, from: field.textInputView)
            }
            let size = text.size()
            rect.size.width = max(rect.width, ceil(size.width))
            rect.size.height = max(rect.height, ceil(size.height))
        }
        context.saveGState()
        context.clip(to: clip)
        text.draw(in: rect)
        context.restoreGState()
    }

    private static func isHiddenPlaceholder(_ value: NSAttributedString?) -> Bool {
        guard let value, value.length > 0 else { return false }
        return value.attribute(placeholderMarker, at: 0, effectiveRange: nil) as? Bool == true
    }
}

@MainActor
final class NBAuroraChromeObserver: ObservableObject {
    @Published private(set) var glyphs: [NBAuroraNativeGlyph] = []
    private weak var anchor: UIView?
    private var sources: [ObjectIdentifier: NBAuroraChromeSource] = [:]
    private var link: CADisplayLink?
    private var displayTarget: NBAuroraChromeDisplayTarget?
    private var lastScan: CFTimeInterval = -.infinity

    func start(at anchor: UIView) {
        if self.anchor !== anchor {
            stop()
            self.anchor = anchor
        }
        guard link == nil else { return }
        let target = NBAuroraChromeDisplayTarget(owner: self)
        displayTarget = target
        let link = CADisplayLink(target: target, selector: #selector(NBAuroraChromeDisplayTarget.fire(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        self.link = link
        update(at: CACurrentMediaTime())
    }

    func stop() {
        link?.invalidate()
        link = nil
        for source in sources.values { source.retire() }
        sources.removeAll()
        displayTarget?.sources = []
        displayTarget = nil
        if !glyphs.isEmpty { glyphs = [] }
        lastScan = -.infinity
    }

    fileprivate func update(at time: CFTimeInterval) {
        guard let anchor, let window = anchor.window else { stop(); return }
        // Discover/recycle views four times per second. Track only the known
        // glyph geometry between scans, including native title/tab animations.
        // Complementary colors themselves follow the compositor, not this link.
        if time - lastScan >= 0.25 {
            scan(window: window)
            lastScan = time
        }
        var next: [NBAuroraNativeGlyph] = []
        for source in sources.values {
            guard let view = source.view else { continue }
            let visible = NBThemeInspectorRegistry.visibleFrame(of: view, in: window)
            guard !visible.isNull, visible.width > 0, visible.height > 0,
                  let image = source.glyphImage() else { source.restore(); continue }
            var opacity: CGFloat = 1
            var parent = view.superview
            while let current = parent {
                opacity *= current.alpha
                parent = current.superview
            }
            let role: NBThemeRole
            if let field = view as? UISearchTextField {
                role = (field.text ?? "").isEmpty ? .searchPlaceholder : .searchText
            } else {
                role = source.role
            }
            next.append(NBAuroraNativeGlyph(
                source: source, image: image, frame: view.convert(view.bounds, to: anchor),
                visibleFrame: anchor.convert(visible, from: window), ancestorOpacity: Double(opacity),
                role: role, elementID: source.elementID
            ))
        }
        next.sort { $0.id < $1.id }
        if next != glyphs { glyphs = next }
    }

    private func scan(window: UIWindow) {
        // Confine each overlay to its presentation's controller hierarchy.
        // Main content and glass drawers must never mask each other's glyphs
        // or paint over a separately presented system panel.
        guard let root = presentationRoot(in: window) else { return }
        var found: Set<ObjectIdentifier> = []

        func add(_ view: UIView, role: NBThemeRole, elementID: String? = nil) {
            let visible = NBThemeInspectorRegistry.visibleFrame(of: view, in: window)
            guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }
            if let label = view as? UILabel,
               (label.text ?? "").isEmpty && (label.attributedText?.length ?? 0) == 0 { return }
            let nativeTint = (view as? UIImageView)?.tintColor ?? (view as? UILabel)?.textColor
            let tint = NBThemeManager.shared.activeColor(for: role).uiColor
            if role == .barButtonTint, let nativeTint, !nativeTint.isEqual(tint) {
                // A palette may intentionally share its accent and success
                // colors. The intended bar role wins when those are equal.
                for status in [NBThemeRole.danger, .warning, .success] {
                    if nativeTint.isEqual(NBThemeManager.shared.activeColor(for: status).uiColor) { return }
                }
            }
            if let icon = view as? UIImageView {
                guard let image = icon.image,
                      image.isSymbolImage || image.renderingMode == .alwaysTemplate else { return }
            }
            let id = ObjectIdentifier(view)
            found.insert(id)
            if let existing = sources[id] {
                existing.role = role
                existing.elementID = elementID
            } else {
                sources[id] = NBAuroraChromeSource(view: view, role: role, elementID: elementID)
            }
        }

        func search(_ field: UISearchTextField) {
            add(field, role: .searchText)
            var pending = field.subviews
            while let view = pending.popLast() {
                pending.append(contentsOf: view.subviews)
                if let icon = view as? UIImageView { add(icon, role: .searchTint) }
            }
        }

        func navigation(_ bar: UINavigationBar) {
            var pending = bar.subviews
            while let view = pending.popLast() {
                if let field = view as? UISearchTextField { search(field); continue }
                pending.append(contentsOf: view.subviews)
                if let label = view as? UILabel {
                    let isTitle = label.text == bar.topItem?.title
                    add(label, role: isTitle ? (label.font.pointSize >= 22 ? .navigationTitle : .navigationText)
                        : .barButtonTint)
                } else if let icon = view as? UIImageView {
                    add(icon, role: .barButtonTint)
                }
            }
        }

        func tabs(_ bar: UITabBar) {
            func controls(in view: UIView) -> [UIControl] {
                view.subviews.flatMap { child -> [UIControl] in
                    guard !child.isHidden, child.alpha > 0.02 else { return [] }
                    if let control = child as? UIControl, child.bounds.width > 10 { return [control] }
                    return controls(in: child)
                }
            }
            let rtl = bar.effectiveUserInterfaceLayoutDirection == .rightToLeft
            let buttons = controls(in: bar).sorted {
                let lhs = $0.convert($0.bounds, to: bar).minX
                let rhs = $1.convert($1.bounds, to: bar).minX
                return rtl ? lhs > rhs : lhs < rhs
            }
            let items = bar.items ?? []
            // Unknown native layouts retain their original paint rather than
            // risk pairing an icon with a different tab's color/override.
            guard buttons.count == items.count else { return }
            for (index, item) in items.enumerated() {
                let selected = item === bar.selectedItem
                let role: NBThemeRole = selected ? .tabSelected : .tabUnselected
                let prefix = "tab.item|\(item.title ?? String(index))|\(selected ? "selected" : "normal")|"
                var pending = buttons[index].subviews
                while let view = pending.popLast() {
                    pending.append(contentsOf: view.subviews)
                    if view is UILabel { add(view, role: role, elementID: prefix + "text") }
                    if view is UIImageView { add(view, role: role, elementID: prefix + "icon") }
                }
            }
        }

        var pending = [root]
        while let view = pending.popLast() {
            guard !view.isHidden, view.alpha > 0.02 else { continue }
            if let bar = view as? UINavigationBar { navigation(bar); continue }
            if let bar = view as? UITabBar { tabs(bar); continue }
            if let field = view as? UISearchTextField { search(field); continue }
            pending.append(contentsOf: view.subviews)
        }
        for id in Array(sources.keys) where !found.contains(id) {
            sources.removeValue(forKey: id)?.retire()
        }
        // The weak display-link hop also owns restoration until the next tick
        // if SwiftUI discards this observer without delivering onDisappear.
        displayTarget?.sources = Array(sources.values)
    }

    private func presentationRoot(in window: UIWindow) -> UIView? {
        var responder: UIResponder? = anchor
        while let current = responder {
            if var controller = current as? UIViewController {
                while let parent = controller.parent { controller = parent }
                return controller.view
            }
            responder = current.next
        }
        return window.rootViewController?.view
    }
}

@MainActor
private final class NBAuroraChromeDisplayTarget: NSObject {
    weak var owner: NBAuroraChromeObserver?
    var sources: [NBAuroraChromeSource] = []
    init(owner: NBAuroraChromeObserver) { self.owner = owner }
    @objc func fire(_ link: CADisplayLink) {
        guard let owner else {
            for source in sources { source.retire() }
            sources = []
            link.invalidate()
            return
        }
        owner.update(at: link.timestamp)
    }
}

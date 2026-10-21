import Foundation

// Only platform interfaces are doubled. The production discovery, geometry,
// caching, masking, text restoration and display-link ownership run unchanged.
protocol ObservableObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
typealias CFTimeInterval = Double
func CACurrentMediaTime() -> Double { 0 }

final class UIColor: NSObject, @unchecked Sendable {
    static let clear = UIColor(), black = UIColor(), white = UIColor()
    static let red = UIColor(), orange = UIColor(), green = UIColor()
    static let label = UIColor(), placeholderText = UIColor()
}
final class UIImage: NSObject, @unchecked Sendable {
    enum RenderingMode { case alwaysTemplate, alwaysOriginal }
    var isSymbolImage = true
    var renderingMode = RenderingMode.alwaysTemplate
    let cgImage: CGImage? = CGImage()
}
final class CGImage: @unchecked Sendable { var hasPixels = true }
struct CGColorSpace {}
func CGColorSpaceCreateDeviceRGB() -> CGColorSpace { CGColorSpace() }
enum CGImageAlphaInfo: UInt32 { case premultipliedLast = 1 }
enum CGBitmapInfo: UInt32 { case byteOrder32Big = 0x4000 }
final class UIFont: NSObject {
    var pointSize: CGFloat = 34
    static let systemFontSize: CGFloat = 17
    static func systemFont(ofSize: CGFloat) -> UIFont { UIFont() }
}
extension NSAttributedString.Key {
    static let foregroundColor = Self("foregroundColor")
    static let font = Self("font"), paragraphStyle = Self("paragraphStyle")
}
final class NSMutableParagraphStyle {
    var alignment = TextAlignment.left
    enum LineBreakMode { case byClipping }
    var lineBreakMode = LineBreakMode.byClipping
}
@MainActor enum DrawingStats {
    static var strings: [String] = []
    static var lastColor: UIColor?
}
extension NSAttributedString {
    func size() -> CGSize { CGSize(width: string.count * 10, height: 20) }
    @MainActor func draw(in rect: CGRect) {
        DrawingStats.strings.append(string)
        DrawingStats.lastColor = attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
    }
}
enum TextAlignment: Int { case left, right }
enum LayoutDirection { case leftToRight, rightToLeft }

@MainActor final class CALayer {
    var mask: CALayer?
    var maskAtLastRender: CALayer?
    func displayIfNeeded() {}
    func render(in context: DrawingContext) { maskAtLastRender = mask }
}
@MainActor enum CATransaction {
    static func begin() {}
    static func commit() {}
    static func setDisableActions(_ value: Bool) {}
}
final class CGContext {
    private var data: UnsafeMutableRawPointer?
    init() {}
    init?(data: UnsafeMutableRawPointer?, width: Int, height: Int, bitsPerComponent: Int,
          bytesPerRow: Int, space: CGColorSpace, bitmapInfo: UInt32) { self.data = data }
    func draw(_ image: CGImage, in rect: CGRect) {
        if image.hasPixels { data?.assumingMemoryBound(to: UInt8.self)[3] = 255 }
    }
    func saveGState() {}
    func restoreGState() {}
    func clip(to rect: CGRect) {}
}
typealias DrawingContext = CGContext
@MainActor final class UIGraphicsImageRendererFormat {
    var scale: CGFloat = 1
    var opaque = false
}
@MainActor final class UIGraphicsImageRenderer {
    static var captures = 0
    static var emptyCapture = false
    struct Context { let cgContext = DrawingContext() }
    init(bounds: CGRect, format: UIGraphicsImageRendererFormat) {}
    func image(actions: (Context) -> Void) -> UIImage {
        Self.captures += 1
        actions(Context())
        let image = UIImage()
        image.cgImage?.hasPixels = !Self.emptyCapture
        return image
    }
}

@MainActor class UIResponder: NSObject { var next: UIResponder? { nil } }
@MainActor class UIView: UIResponder {
    var bounds = CGRect(x: 0, y: 0, width: 300, height: 44)
    var isHidden = false
    var alpha: CGFloat = 1
    var layer = CALayer()
    var tintColor: UIColor = .white
    var subviews: [UIView] = []
    weak var superview: UIView?
    weak var responderOverride: UIResponder?
    override var next: UIResponder? { responderOverride ?? superview }
    var window: UIWindow? { (self as? UIWindow) ?? superview?.window }
    var effectiveUserInterfaceLayoutDirection = LayoutDirection.leftToRight
    func convert(_ rect: CGRect, to: UIView?) -> CGRect { rect }
    func convert(_ rect: CGRect, from: UIView?) -> CGRect { rect }
    func layoutIfNeeded() {}
    func addSubview(_ view: UIView) { subviews.append(view); view.superview = self }
    func removeSubviews() {
        for view in subviews { view.superview = nil }
        subviews = []
    }
}
@MainActor final class UILabel: UIView {
    var text: String?
    var attributedText: NSAttributedString?
    var font = UIFont()
    var textColor: UIColor = .white
    var textAlignment = TextAlignment.left
    var numberOfLines = 1
}
@MainActor final class UIImageView: UIView {
    var image: UIImage? = UIImage()
    var highlightedImage: UIImage?
    var isHighlighted = false
}
@MainActor class UIControl: UIView {}
@MainActor final class UITableView: UIView {
    var tableHeaderView: UIView?
    var tableFooterView: UIView?
}
@MainActor final class UICollectionView: UIView {
    static let elementKindSectionHeader = "header", elementKindSectionFooter = "footer"
    var supplementary: [String: [UIView]] = [:]
    func visibleSupplementaryViews(ofKind kind: String) -> [UIView] { supplementary[kind] ?? [] }
}
@MainActor final class UITableViewCell: UIView {}
@MainActor final class UICollectionViewCell: UIView {}
@MainActor final class UITableViewHeaderFooterView: UIView {}
@MainActor final class UnscannableRowContent: UIView {
    override var subviews: [UIView] {
        get { preconditionFailure("Chrome discovery descended into list row content") }
        set { super.subviews = newValue }
    }
}
struct UITextPosition { let offset: Int }
struct UITextRange { let start: UITextPosition; let end: UITextPosition }
@MainActor final class UISearchTextField: UIControl {
    var text: String?
    var attributedText: NSAttributedString?
    var textColor: UIColor? = .white
    var font: UIFont? = UIFont()
    var textAlignment = TextAlignment.left
    var isEditing = false
    var selectedTextRange: UITextRange?
    let beginningOfDocument = UITextPosition(offset: 0)
    var endOfDocument: UITextPosition { UITextPosition(offset: (text ?? "").count) }
    var textInputView: UIView { self }
    var defaultTextAttributes: [NSAttributedString.Key: Any] {
        [.foregroundColor: textColor ?? UIColor.label]
    }
    func textRange(from: UITextPosition, to: UITextPosition) -> UITextRange? { UITextRange(start: from, end: to) }
    func firstRect(for: UITextRange) -> CGRect { bounds }
    func offset(from: UITextPosition, to: UITextPosition) -> Int { to.offset - from.offset }
    private var plainPlaceholder: String?
    var attributedPlaceholder: NSAttributedString? {
        didSet { plainPlaceholder = attributedPlaceholder?.string }
    }
    var placeholder: String? {
        get { plainPlaceholder }
        set { plainPlaceholder = newValue; attributedPlaceholder = newValue.map(NSAttributedString.init(string:)) }
    }
    func placeholderRect(forBounds rect: CGRect) -> CGRect { rect }
    func editingRect(forBounds rect: CGRect) -> CGRect { rect }
    func textRect(forBounds rect: CGRect) -> CGRect { rect }
}
@MainActor final class UINavigationItem { var title: String? }
@MainActor final class UINavigationBar: UIView { var topItem: UINavigationItem? = UINavigationItem() }
@MainActor final class UITabBarItem {
    var title: String?
    init(_ title: String) { self.title = title }
}
@MainActor final class UITabBar: UIView {
    var items: [UITabBarItem]?
    var selectedItem: UITabBarItem?
}
@MainActor final class UIViewController: UIResponder {
    let view = UIView()
    var parent: UIViewController?
}
@MainActor final class UIScreen { var scale: CGFloat = 3 }
@MainActor final class UIWindow: UIView {
    let screen = UIScreen()
    var rootViewController: UIViewController?
}

struct CAFrameRateRange {
    init(minimum: Float, maximum: Float, preferred: Float) {}
}
@MainActor final class CADisplayLink {
    static var lastCreated: CADisplayLink?
    let target: NSObject
    var preferredFrameRateRange = CAFrameRateRange(minimum: 0, maximum: 0, preferred: 0)
    var timestamp: Double = 0
    var invalidated = false
    init(target: NSObject, selector: String) { self.target = target; Self.lastCreated = self }
    func add(to: RunLoop, forMode: RunLoop.Mode) {}
    func invalidate() { invalidated = true }
}

enum NBThemeRole {
    case text, heading, danger, warning, success, navigationTitle, navigationText
    case barButtonTint, searchText, searchPlaceholder, searchTint, tabSelected, tabUnselected
}
struct NBThemeColor { let uiColor: UIColor }
@MainActor final class NBThemeManager {
    static let shared = NBThemeManager()
    func activeColor(for role: NBThemeRole) -> NBThemeColor {
        NBThemeColor(uiColor: role == .danger ? .red : role == .warning ? .orange : role == .success ? .green : .white)
    }
}
@MainActor enum NBThemeInspectorRegistry {
    static func visibleFrame(of view: UIView, in window: UIWindow) -> CGRect {
        guard view.window === window else { return .null }
        var parent: UIView? = view
        while let node = parent {
            if node.isHidden || node.alpha <= 0.02 { return .null }
            parent = node.superview
        }
        return view.bounds
    }
}

// PRODUCTION_CHROME

@main enum ChromeLifetimeTests {
    @MainActor static func main() {
        sourceLifetime()
        searchLifetime()
        discoveryAndOrphanCleanup()
        presentationIsolation()
        listDiscoveryBoundaries()
        print("Chrome lifecycle tests passed: glyph cache, original masks, input restoration, recycling, tab identity, status preservation and orphan cleanup.")
    }

    @MainActor static func listDiscoveryBoundaries() {
        let window = UIWindow()
        let controller = UIViewController()
        window.rootViewController = controller
        window.addSubview(controller.view)
        let anchor = UIView()
        controller.view.addSubview(anchor)
        let bar = UINavigationBar()
        let title = UILabel()
        title.text = "Library"
        bar.addSubview(title)
        controller.view.addSubview(bar)

        let table = UITableView()
        controller.view.addSubview(table)
        let headerSearch = UISearchTextField()
        headerSearch.placeholder = "Table search"
        let explicitHeader = UITableViewHeaderFooterView()
        explicitHeader.addSubview(headerSearch)
        table.tableHeaderView = explicitHeader
        table.addSubview(explicitHeader)
        let collection = UICollectionView()
        controller.view.addSubview(collection)
        let supplementarySearch = UISearchTextField()
        supplementarySearch.placeholder = "Collection search"
        collection.supplementary[UICollectionView.elementKindSectionHeader] = [supplementarySearch]
        collection.addSubview(supplementarySearch)
        for _ in 0..<103 {
            let cell = UITableViewCell()
            cell.addSubview(UnscannableRowContent())
            table.addSubview(cell)
            let gridCell = UICollectionViewCell()
            gridCell.addSubview(UnscannableRowContent())
            collection.addSubview(gridCell)
        }
        // Reuse/transition containers may also temporarily host detached cells.
        let detachedCell = UITableViewCell()
        detachedCell.addSubview(UnscannableRowContent())
        controller.view.addSubview(detachedCell)
        let observer = NBAuroraChromeObserver()
        observer.start(at: anchor)
        assert(observer.glyphs.count == 3, "Bars and explicit search headers must remain discoverable")
        let link = CADisplayLink.lastCreated!
        let target = link.target as! NBAuroraChromeDisplayTarget
        link.timestamp = 0.3
        target.fire(link)
        assert(observer.glyphs.count == 3, "Repeated discovery must keep skipping all cell trees")
        observer.stop()
        print("Chrome discovery passed: 206 list/grid cells skipped; navigation and explicit header search retained.")
    }

    @MainActor static func sourceLifetime() {
        let label = UILabel()
        label.text = "Downloads"
        let original = CALayer()
        label.layer.mask = original
        let source = NBAuroraChromeSource(view: label, role: .navigationTitle, elementID: nil)
        let first = source.glyphImage()!
        source.hide()
        let hidden = label.layer.mask
        assert(hidden !== original)
        assert(source.glyphImage() === first, "Unchanged glyphs must reuse their bitmap")
        label.text = "Files"
        assert(source.glyphImage() !== first, "Recycled labels must refresh their glyph")
        assert(label.layer.maskAtLastRender === original, "Capture must restore the native mask first")
        assert(label.layer.mask === hidden, "Capture must re-hide the native paint")
        source.restore()
        assert(label.layer.mask === original)
        source.hide()
        let external = CALayer()
        label.layer.mask = external
        source.restore()
        assert(label.layer.mask === external, "External mask changes must survive teardown")
        source.retire()
        source.hide()
        assert(label.layer.mask === external, "A late overlay appearance must not re-hide retired views")
        let emptyLabel = UILabel()
        emptyLabel.text = "Unsupported native drawing"
        let emptySource = NBAuroraChromeSource(view: emptyLabel, role: .navigationText, elementID: nil)
        UIGraphicsImageRenderer.emptyCapture = true
        assert(emptySource.glyphImage() == nil, "Empty native captures must not produce overlay glyphs")
        UIGraphicsImageRenderer.emptyCapture = false
        assert(emptyLabel.layer.mask == nil, "Native paint must remain visible when capture fails")
    }

    @MainActor static func searchLifetime() {
        let field = UISearchTextField()
        field.attributedPlaceholder = NSAttributedString(string: "Search", attributes: [.foregroundColor: UIColor.white])
        let original = field.attributedPlaceholder!
        let source = NBAuroraChromeSource(view: field, role: .searchPlaceholder, elementID: nil)
        _ = source.glyphImage()
        assert(DrawingStats.strings.last == "Search")
        source.hide()
        source.hide()
        assert(field.textColor == .clear)
        assert(field.attributedPlaceholder != original)
        field.text = "Example.ipa"
        field.isEditing = true
        _ = source.glyphImage()
        assert(DrawingStats.strings.last == "Example.ipa" && field.textColor == .clear)
        assert(DrawingStats.lastColor == .white, "Capture must draw the original text color before re-hiding it")
        let draws = DrawingStats.strings.count
        field.selectedTextRange = UITextRange(start: UITextPosition(offset: 2), end: UITextPosition(offset: 2))
        _ = source.glyphImage()
        assert(DrawingStats.strings.count == draws + 1, "Moving a cursor in scrolled input must refresh its visible text")
        source.restore()
        assert(field.textColor == .white && field.attributedPlaceholder == original)
        source.hide()
        field.textColor = .green
        let updated = NSAttributedString(string: "Find", attributes: [.foregroundColor: UIColor.green])
        field.attributedPlaceholder = updated
        source.restore()
        assert(field.textColor == .green && field.attributedPlaceholder == updated,
               "Theme refreshes must survive restoration")
        field.textColor = .clear
        let transparent = NBAuroraChromeSource(view: field, role: .searchText, elementID: nil)
        transparent.hide()
        transparent.restore()
        assert(field.textColor == .clear, "An intentionally transparent input must stay transparent")
    }

    @MainActor static func discoveryAndOrphanCleanup() {
        let window = UIWindow()
        let controller = UIViewController()
        window.rootViewController = controller
        window.addSubview(controller.view)
        let anchor = UIView()
        controller.view.addSubview(anchor)
        let nav = UINavigationBar()
        nav.topItem?.title = "Downloads"
        controller.view.addSubview(nav)
        let title = UILabel()
        title.text = "Downloads"
        nav.addSubview(title)
        let destructive = UIImageView()
        destructive.tintColor = .red
        nav.addSubview(destructive)
        let deleteLabel = UILabel()
        deleteLabel.text = "Delete"
        deleteLabel.textColor = .red
        nav.addSubview(deleteLabel)
        let field = UISearchTextField()
        field.placeholder = "Search"
        nav.addSubview(field)
        let tabs = UITabBar()
        let item = UITabBarItem("Downloads")
        tabs.items = [item]
        tabs.selectedItem = item
        let button = UIControl()
        let icon = UIImageView()
        button.addSubview(icon)
        tabs.addSubview(button)
        controller.view.addSubview(tabs)

        var observer: NBAuroraChromeObserver? = NBAuroraChromeObserver()
        observer!.start(at: anchor)
        assert(observer!.glyphs.count == 3)
        assert(observer!.glyphs.contains { $0.role == .navigationTitle })
        assert(observer!.glyphs.contains { $0.elementID == "tab.item|Downloads|selected|icon" })
        let link = CADisplayLink.lastCreated!
        let target = link.target as! NBAuroraChromeDisplayTarget
        for glyph in observer!.glyphs { glyph.source.hide() }
        assert(title.layer.mask != nil && field.textColor == .clear)
        tabs.selectedItem = nil
        link.timestamp = 0.3
        target.fire(link)
        assert(observer!.glyphs.contains { $0.elementID == "tab.item|Downloads|normal|icon" })
        assert(destructive.layer.mask == nil)
        assert(deleteLabel.layer.mask == nil)
        tabs.items = []
        link.timestamp = 0.6
        target.fire(link)
        assert(icon.layer.mask == nil, "Unknown native tab layouts must retain their native paint")
        tabs.items = [item]
        nav.isHidden = true
        link.timestamp = 0.9
        target.fire(link)
        assert(title.layer.mask == nil && field.textColor == .white, "Recycled/offscreen chrome must be restored")
        nav.isHidden = false
        link.timestamp = 1.2
        target.fire(link)
        for glyph in observer!.glyphs { glyph.source.hide() }
        observer!.stop()
        assert(title.layer.mask == nil && icon.layer.mask == nil && field.textColor == .white)
        assert(link.invalidated && observer!.glyphs.isEmpty)
        observer!.start(at: anchor)
        for glyph in observer!.glyphs { glyph.source.hide() }
        let orphanLink = CADisplayLink.lastCreated!
        let orphanTarget = orphanLink.target as! NBAuroraChromeDisplayTarget
        observer = nil
        orphanTarget.fire(orphanLink)
        assert(title.layer.mask == nil && icon.layer.mask == nil && field.textColor == .white)
        assert(orphanLink.invalidated, "A lost owner must restore its native glyphs and invalidate the link")
    }

    @MainActor static func presentationIsolation() {
        let window = UIWindow()
        let main = UIViewController()
        window.rootViewController = main
        window.addSubview(main.view)
        let mainAnchor = UIView()
        main.view.addSubview(mainAnchor)
        let mainBar = UINavigationBar()
        main.view.addSubview(mainBar)
        let mainTitle = UILabel()
        mainTitle.text = "Main"
        mainBar.addSubview(mainTitle)

        let sheet = UIViewController()
        window.addSubview(sheet.view)
        let hosted = UIViewController()
        hosted.parent = sheet
        sheet.view.addSubview(hosted.view)
        let sheetAnchor = UIView()
        sheetAnchor.responderOverride = hosted
        hosted.view.addSubview(sheetAnchor)
        let sheetBar = UINavigationBar()
        sheet.view.addSubview(sheetBar)
        let sheetTitle = UILabel()
        sheetTitle.text = "Sheet"
        sheetBar.addSubview(sheetTitle)

        let mainObserver = NBAuroraChromeObserver()
        let sheetObserver = NBAuroraChromeObserver()
        mainObserver.start(at: mainAnchor)
        sheetObserver.start(at: sheetAnchor)
        assert(mainObserver.glyphs.count == 1 && mainObserver.glyphs[0].source.view === mainTitle)
        assert(sheetObserver.glyphs.count == 1 && sheetObserver.glyphs[0].source.view === sheetTitle)
        mainObserver.glyphs[0].source.hide()
        sheetObserver.glyphs[0].source.hide()
        mainObserver.stop()
        assert(mainTitle.layer.mask == nil && sheetTitle.layer.mask != nil,
               "A main container must not restore or mask a presented container's glyphs")
        sheetObserver.stop()
        assert(sheetTitle.layer.mask == nil)
    }
}

import SwiftUI
import UIKit

// UIKit bars and list supplementary views can composite their foregrounds in
// separate containers. Paint their glyphs in one overlay above those containers
// so difference blending can see the same backing as ordinary screen content.
// The original controls still own layout, input, focus and accessibility.

private struct NBAuroraChromeInstalledKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var nbAuroraChromeInstalled: Bool {
        get { self[NBAuroraChromeInstalledKey.self] }
        set { self[NBAuroraChromeInstalledKey.self] = newValue }
    }
}

private final class NBAuroraHeaderPaint: ObservableObject {
    @Published var isPainted = false
}

private struct NBAuroraHeaderGlyph {
    let bounds: Anchor<CGRect>
    let view: AnyView
    let paint: NBAuroraHeaderPaint
}

private struct NBAuroraHeaderGlyphKey: PreferenceKey {
    static var defaultValue: [UUID: NBAuroraHeaderGlyph] { [:] }
    static func reduce(value: inout [UUID: NBAuroraHeaderGlyph],
                       nextValue: () -> [UUID: NBAuroraHeaderGlyph]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

public extension View {
    /// Install once outside a navigation/tab container. This keeps native bar
    /// glyphs above their glass without replacing the controls themselves.
    /// A separately presented root can opt into its own overlay scope.
    func nbThemeAdaptiveChrome(inPresentation: Bool = false) -> some View {
        modifier(NBAuroraChromeModifier(inPresentation: inPresentation))
    }

    /// A foreground that can escape a list header's isolated hosting surface.
    func nbThemeChromeForeground(
        _ role: NBThemeRole,
        elementID: String? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> some View {
        modifier(NBAuroraHeaderModifier(role: role,
                                       elementID: elementID ?? "\(fileID):\(line):\(column)"))
    }
}

private struct NBAuroraHeaderModifier: ViewModifier {
    @Environment(\.nbAuroraChromeInstalled) private var installed
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("Feather.auroraBackground") private var aurora = true
    @AppStorage("Feather.auroraAdaptiveText") private var adaptive = true
    @State private var id = UUID()
    @StateObject private var paint = NBAuroraHeaderPaint()
    let role: NBThemeRole
    let elementID: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if installed && aurora && adaptive && !reduceTransparency && contrast != .increased {
            content
                // The original retains its accessibility and layout. Never
                // hide it until an overlay actually consumes its preference.
                .opacity(paint.isPainted ? 0 : 1)
                .anchorPreference(key: NBAuroraHeaderGlyphKey.self, value: .bounds) { bounds in
                    [id: NBAuroraHeaderGlyph(
                        bounds: bounds,
                        view: AnyView(content.nbThemeForeground(role, elementID: elementID)),
                        paint: paint
                    )]
                }
        } else {
            content.nbThemeForeground(role, elementID: elementID)
        }
    }
}

private struct NBAuroraChromeModifier: ViewModifier {
    @Environment(\.nbAuroraChromeInstalled) private var installed
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("Feather.auroraBackground") private var aurora = true
    @AppStorage("Feather.auroraAdaptiveText") private var adaptive = true
    var inPresentation = false

    private var enabled: Bool {
        aurora && adaptive && !reduceTransparency && contrast != .increased
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if installed && !inPresentation {
            content
        } else {
            content
                .environment(\.nbAuroraChromeInstalled, true)
                .overlayPreferenceValue(NBAuroraHeaderGlyphKey.self) { headers in
                    GeometryReader { geometry in
                        if enabled {
                            ForEach(Array(headers.keys), id: \.self) { id in
                                if let glyph = headers[id] {
                                    let rect = geometry[glyph.bounds]
                                    glyph.view
                                        .frame(width: rect.width, height: rect.height)
                                        .position(x: rect.midX, y: rect.midY)
                                        .onAppear { glyph.paint.isPainted = true }
                                        .onDisappear { glyph.paint.isPainted = false }
                                }
                            }
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .overlay {
                    NBAuroraNativeChromeOverlay(enabled: enabled && scenePhase == .active)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .transformPreference(NBAuroraHeaderGlyphKey.self) { $0 = [:] }
        }
    }
}

private struct NBAuroraNativeChromeOverlay: View {
    @StateObject private var observer = NBAuroraChromeObserver()
    @ObservedObject private var themes = NBThemeManager.shared
    let enabled: Bool

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                ForEach(observer.glyphs) { glyph in
                    let color = themes.activeColor(for: glyph.role, elementID: glyph.elementID)
                    // The captured alpha already includes the native color's
                    // opacity. Apply its RGB once, without dimming it twice.
                    let ink = NBThemeColor(red: color.red, green: color.green, blue: color.blue)
                    Image(uiImage: glyph.image)
                        .renderingMode(.template)
                        .resizable()
                        .modifier(NBAuroraTextStyleModifier(
                            primary: ink,
                            adaptsPrimary: !themes.isPreviewing(glyph.role, in: themes.selectedThemeID)
                                && !(glyph.elementID.map { themes.hasElementOverride($0) } ?? false)
                        ))
                        .frame(width: glyph.frame.width, height: glyph.frame.height)
                        .offset(x: glyph.frame.minX - glyph.visibleFrame.minX,
                                y: glyph.frame.minY - glyph.visibleFrame.minY)
                        .frame(width: glyph.visibleFrame.width, height: glyph.visibleFrame.height,
                               alignment: .topLeading)
                        .clipped()
                        .opacity(glyph.ancestorOpacity)
                        .position(x: glyph.visibleFrame.midX, y: glyph.visibleFrame.midY)
                        .onAppear { glyph.source.hide() }
                        .onDisappear { glyph.source.restore() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(NBAuroraChromeAnchor(observer: observer, enabled: enabled))
        }
        .transaction { $0.animation = nil }
        .onChange(of: enabled) { if !$0 { observer.stop() } }
        .onDisappear { observer.stop() }
    }
}

private struct NBAuroraChromeAnchor: UIViewRepresentable {
    let observer: NBAuroraChromeObserver
    let enabled: Bool

    func makeUIView(context: Context) -> NBAuroraChromeAnchorView {
        let view = NBAuroraChromeAnchorView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: NBAuroraChromeAnchorView, context: Context) {
        view.observer = observer
        view.enabled = enabled
        view.scheduleUpdate()
    }
}

private final class NBAuroraChromeAnchorView: UIView {
    weak var observer: NBAuroraChromeObserver?
    var enabled = false
    private var pending = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleUpdate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleUpdate()
    }

    func scheduleUpdate() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            if self.enabled, self.window != nil {
                self.observer?.start(at: self)
            } else {
                self.observer?.stop()
            }
        }
    }
}

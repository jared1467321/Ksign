//
//  ThemeColorInspectorView.swift
//  Ksign
//
//  A temporary, in-context color editing session. App screens below are their
//  real SwiftUI views and UIKit bars, not screenshots. State-dependent colors,
//  Crypt Check reports, and the widget use an explicitly labeled example.
//

import SwiftUI
import UIKit
import NimbleViews
import NimbleExtensions

struct ThemeColorInspectorView: View {
    let role: NBThemeRole
    let themeID: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var themes = NBThemeManager.shared
    @State private var didBeginPreview = false
    @State private var appearancePath = ["appearance"]
    @State private var compact = false
    @State private var dockAtTop = false
    @State private var spotlightRect: CGRect?

    private var original: NBThemeColor {
        themes.profile(id: themeID)?.color(for: role) ?? NBThemeProfile.halloween.color(for: role)
    }

    private var current: NBThemeColor { themes.activeColor(for: role) }

    var body: some View {
        ZStack {
            if role.usesRealScreen {
                realScreen
                    .environment(\.managedObjectContext, Storage.shared.context)
                    .environment(\.nbInspectedThemeRole, role)
            } else {
                exampleScreen
            }

            if role.usesUIKitSpotlight {
                GeometryReader { geometry in
                    ThemeUIKitSpotlightProbe(role: role, revision: themes.previewRevision) { rect in
                        spotlightRect = rect
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)

                    if let rect = spotlightRect {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.yellow, lineWidth: 3)
                            .shadow(color: .black.opacity(0.85), radius: 4)
                            .frame(width: rect.width + 6, height: rect.height + 6)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            VStack {
                if !dockAtTop { Spacer(minLength: 0) }
                editorPanel
                    .frame(maxWidth: 540)
                    .padding(.horizontal, 12)
                    .padding(.top, dockAtTop ? 52 : 0)
                    .padding(.bottom, dockAtTop ? 0 : (role.usesRealScreen ? 74 : 16))
                if dockAtTop { Spacer(minLength: 0) }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .interactiveDismissDisabled()
        .onAppear {
            guard !didBeginPreview else { return }
            didBeginPreview = true
            themes.beginColorPreview(for: role, in: themeID)
        }
        // The presenting cover cancels on dismissal. onDisappear is not a
        // session boundary: a nested app screen can temporarily cover us.
        .onChange(of: themes.selectedThemeID) { selected in
            if selected != themeID { dismiss() }
        }
    }

    @ViewBuilder
    private var realScreen: some View {
        switch role.realScreen {
        case .appearance:
            // This is the real Appearance page, whose NBList paints the page,
            // rows, and profile labels we spotlight. It is NOT the fake sample.
            if role == .navigationTint || role == .navigationText {
                NavigationStack(path: $appearancePath) {
                    NBList(.localized("Settings")) {
                        NavigationLink(value: "appearance") {
                            Label(.localized("Appearance"), systemImage: "paintbrush")
                        }
                    }
                        .navigationDestination(for: String.self) { _ in
                            AppearanceView()
                                .navigationBarTitleDisplayMode(.inline)
                        }
                }
            } else {
                NBNavigationView(.localized("Appearance")) { AppearanceView() }
            }
        case .library:
            // Use the real tab container: UIKit search/segment/nav/tab chrome
            // exists here and the current library contents remain live.
            VariedTabbarView(previewTab: .library)
        }
    }

    private var exampleScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(role.category == .liveActivity ? "Live Activity example" :
                      role.category == .reports ? "Crypt Check report example" :
                      "Component example", systemImage: "eye")
                    .font(.headline)
                    .foregroundStyle(.white)

                Text(role.category == .liveActivity
                     ? "The Live Activity runs in a separate system widget. This is an interactive, on-screen example; an active widget is refreshed after you save."
                     : role.category == .reports
                     ? "Reports are separate HTML documents and may not exist yet. This interactive example uses your current report colors; saved colors apply to newly generated reports."
                     : "This color is state-dependent or has no guaranteed visible instance on an app page. This is a labeled interactive example, not a claim that the actual screen is open.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.73))
                    .fixedSize(horizontal: false, vertical: true)

                ThemeRoleExampleView(role: role)
                    .environment(\.nbInspectedThemeRole, role)
                    .padding(20)
                    .frame(maxWidth: .infinity, minHeight: 205)
                    .background(NBHalloween.elevated, in: RoundedRectangle(cornerRadius: 18))

                Text(role.usageDescription)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.76))
            }
            .padding(.horizontal, 20)
            .padding(.top, 34)
            .padding(.bottom, 425)
        }
        .background(NBHalloween.background.ignoresSafeArea())
    }

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(spacing: 8) {
                Image(systemName: "location.viewfinder")
                    .foregroundStyle(.yellow)
                Text(role.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 5)
                Button {
                    dockAtTop.toggle()
                } label: {
                    Image(systemName: dockAtTop ? "arrow.down.to.line.compact" : "arrow.up.to.line.compact")
                }
                .accessibilityLabel(dockAtTop ? "Move editor to bottom" : "Move editor to top")
                Button {
                    compact.toggle()
                } label: {
                    Image(systemName: compact ? "chevron.up" : "chevron.down")
                }
                .accessibilityLabel(compact ? "Expand color controls" : "Collapse color controls")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)

            if !compact {
                Text(role.usageDescription)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.74))
                    .fixedSize(horizontal: false, vertical: true)

                if role.usesUIKitSpotlight && spotlightRect == nil {
                    Text("The control isn't visible on this screen right now. You can reveal it on the real page, or use the highlighted example below.")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                    ThemeRoleExampleView(role: role)
                        .environment(\.nbInspectedThemeRole, role)
                        .frame(maxWidth: .infinity, minHeight: 55)
                        .padding(6)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                HStack(spacing: 12) {
                    ColorPicker("Color", selection: colorBinding, supportsOpacity: true)
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hexValue)
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        Text(current.alpha < 0.999 ? "Opacity: \(Int((current.alpha * 100).rounded()))%" : "Fully opaque")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                    Button("Original") { themes.updateColorPreview(original, for: role, in: themeID) }
                        .font(.caption.weight(.semibold))
                        .disabled(current == original)
                }

                // Inline controls leave the actual app visible while dragging.
                slider("Hue", component: .hue)
                slider("Saturation", component: .saturation)
                slider("Brightness", component: .brightness)
                slider("Opacity", component: .alpha)
            }

            HStack(spacing: 9) {
                Button("Cancel") { finish(save: false) }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
                Button("Save Color") { finish(save: true) }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
        }
        .padding(14)
        .foregroundStyle(.white)
        .tint(.yellow)
        .background(Color(uiColor: UIColor(white: 0.105, alpha: 0.97)), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.white.opacity(0.23), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 15)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { themes.activeColor(for: role).color },
            set: { themes.updateColorPreview(NBThemeColor(uiColor: UIColor($0)), for: role, in: themeID) }
        )
    }

    private enum ColorComponent { case hue, saturation, brightness, alpha }

    private func slider(_ title: String, component: ColorComponent) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption)
                .frame(width: 74, alignment: .leading)
            Slider(value: componentBinding(component), in: 0...1)
                .accessibilityLabel(title)
            Text("\(Int((componentBinding(component).wrappedValue * 100).rounded()))")
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 29, alignment: .trailing)
        }
    }

    private func componentBinding(_ component: ColorComponent) -> Binding<Double> {
        Binding(
            get: {
                let rgba = themes.activeColor(for: role)
                var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
                UIColor(red: CGFloat(rgba.red), green: CGFloat(rgba.green),
                        blue: CGFloat(rgba.blue), alpha: CGFloat(rgba.alpha))
                    .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                switch component {
                case .hue: return Double(hue)
                case .saturation: return Double(saturation)
                case .brightness: return Double(brightness)
                case .alpha: return rgba.alpha
                }
            },
            set: { value in
                let rgba = themes.activeColor(for: role)
                var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
                UIColor(red: CGFloat(rgba.red), green: CGFloat(rgba.green),
                        blue: CGFloat(rgba.blue), alpha: CGFloat(rgba.alpha))
                    .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                switch component {
                case .hue: hue = CGFloat(value)
                case .saturation: saturation = CGFloat(value)
                case .brightness: brightness = CGFloat(value)
                case .alpha: alpha = CGFloat(value)
                }
                let edited = NBThemeColor(uiColor: UIColor(
                    hue: hue, saturation: saturation, brightness: brightness, alpha: alpha
                ))
                themes.updateColorPreview(edited, for: role, in: themeID)
            }
        )
    }

    private var hexValue: String {
        String(format: "#%02X%02X%02X", Int((current.red * 255).rounded()),
               Int((current.green * 255).rounded()), Int((current.blue * 255).rounded()))
    }

    private func finish(save: Bool) {
        themes.endColorPreview(for: role, in: themeID, save: save)
        dismiss()
    }
}

// MARK: - Where an unambiguous, currently renderable real element exists

private enum InspectorRealScreen { case appearance, library }

private extension NBThemeRole {
    var usesRealScreen: Bool {
        switch self {
        case .background, .elevated, .text, .textSecondary, .accent, .heading, .headingFill:
            return true
        default:
            return category == .navigation
        }
    }

    var realScreen: InspectorRealScreen {
        switch self {
        case .background, .elevated, .text, .textSecondary, .navigationTint, .navigationText: return .appearance
        default: return .library
        }
    }

    var usesUIKitSpotlight: Bool { category == .navigation }
}

// MARK: - Exact UIKit bounds for real tab, navigation, search and segment UI

private struct ThemeUIKitSpotlightProbe: UIViewRepresentable {
    let role: NBThemeRole
    let revision: UInt64
    let onRect: (CGRect?) -> Void

    func makeUIView(context: Context) -> ThemeUIKitProbeView {
        let view = ThemeUIKitProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: ThemeUIKitProbeView, context: Context) {
        view.role = role
        view.onRect = onRect
        // UIKit bars can finish laying out after the SwiftUI update. Recheck
        // on the next main-loop turn as well as on each layout pass.
        DispatchQueue.main.async { [weak view] in view?.refresh() }
    }
}

private final class ThemeUIKitProbeView: UIView {
    var role: NBThemeRole = .navigationBackground
    var onRect: ((CGRect?) -> Void)?
    private var previousRect: CGRect?
    private var refreshTimer: Timer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard window != nil else { return }
        // Scrolling and changing tabs need not resize this probe. Track those
        // layout changes too, without publishing unchanged bounds to SwiftUI.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    deinit { refreshTimer?.invalidate() }

    override func layoutSubviews() {
        super.layoutSubviews()
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func refresh() {
        guard let window else { report(nil); return }
        var controller = window.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        let scope = controller?.view ?? window
        var stack = [scope]
        var candidates: [UIView] = []
        while let view = stack.popLast() {
            guard !view.isHidden, view.alpha > 0.02 else { continue }
            if matches(view) { candidates.append(view) }
            stack.append(contentsOf: view.subviews)
        }
        // The current full-screen cover is the uppermost presented controller;
        // never spotlight a same-colored control on the obscured parent page.
        let visible = candidates.first { view in
            let rect = view.convert(view.bounds, to: self)
            return rect.width > 1 && rect.height > 1 &&
                rect.intersects(bounds) && view.window === window
        }
        guard let visible else { report(nil); return }
        var rect = visible.convert(visible.bounds, to: self)
        if let tab = visible as? UITabBar {
            switch role {
            case .tabShadow: rect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 4)
            case .tabSelected, .tabUnselected:
                let items = tab.subviews.compactMap { $0 as? UIControl }
                    .filter { !$0.isHidden && $0.bounds.width > 10 }
                if let item = items.first(where: { $0.isSelected == (role == .tabSelected) }) {
                    rect = item.convert(item.bounds, to: self)
                } else { report(nil); return }
            default: break
            }
        }
        if visible is UINavigationBar, role == .navigationShadow {
            rect = CGRect(x: rect.minX, y: rect.maxY - 4, width: rect.width, height: 4)
        }
        if let segment = visible as? UISegmentedControl,
           [.segmentSelectedBackground, .segmentSelectedText, .segmentText].contains(role),
           segment.numberOfSegments > 0 {
            var index = max(0, segment.selectedSegmentIndex)
            if role == .segmentText { index = (index + 1) % segment.numberOfSegments }
            let width = rect.width / CGFloat(segment.numberOfSegments)
            rect = CGRect(x: rect.minX + width * CGFloat(index), y: rect.minY,
                          width: width, height: rect.height)
        }
        report(rect)
    }

    private func matches(_ view: UIView) -> Bool {
        switch role {
        case .navigationBackground, .navigationShadow: return view is UINavigationBar
        case .navigationTitle, .navigationText:
            guard let label = view as? UILabel,
                  let nav = ancestor(UINavigationBar.self, from: view),
                  let actualTitle = nav.topItem?.title,
                  label.text == actualTitle else { return false }
            return role == .navigationTitle ? label.font.pointSize >= 22 : label.font.pointSize < 22
        case .navigationTint, .barButtonTint:
            guard view is UIButton,
                  ancestor(UINavigationBar.self, from: view) != nil else { return false }
            if role == .navigationTint {
                // An Edit button may be explicitly colored with .accent;
                // only the real back/navigation control represents tint.
                let identifier = [view.accessibilityLabel, view.accessibilityIdentifier]
                    .compactMap { $0 }.joined(separator: " ").lowercased()
                return identifier.contains("back") || identifier.contains("return")
            }
            return true
        case .tabBackground, .tabSelected, .tabUnselected, .tabShadow: return view is UITabBar
        case .searchBackground, .searchText, .searchPlaceholder, .searchTint:
            return view is UISearchTextField
        case .segmentBackground, .segmentSelectedBackground, .segmentText, .segmentSelectedText:
            return view is UISegmentedControl
        default: return false
        }
    }

    private func ancestor<T: UIView>(_ type: T.Type, from view: UIView) -> T? {
        var parent = view.superview
        while let current = parent {
            if let matched = current as? T { return matched }
            parent = current.superview
        }
        return nil
    }

    private func report(_ rect: CGRect?) {
        guard previousRect != rect else { return }
        previousRect = rect
        onRect?(rect)
    }
}

// MARK: - Clearly labeled interactive fallback for non-renderable states

private struct ThemeRoleExampleView: View {
    let role: NBThemeRole
    @StateObject private var themes = NBThemeManager.shared

    private var selected: Color { themes.activeColor(for: role).color }
    private var exampleSurface: Color {
        switch role.category {
        case .reports: return NBHalloween.color(.reportCard)
        case .liveActivity: return NBHalloween.color(.liveActivityBackground)
        default: return NBHalloween.elevated
        }
    }
    private var exampleText: Color {
        switch role.category {
        case .reports: return NBHalloween.color(.reportText)
        case .liveActivity: return NBHalloween.color(.liveActivityPrimaryText)
        default: return NBHalloween.text
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            switch role {
            case .background, .reportBackground:
                VStack(alignment: .leading) {
                    Text("Page content").font(.headline)
                    Text("This entire panel is the page background.").font(.caption)
                }
                .foregroundStyle(exampleText)
                .frame(maxWidth: .infinity, minHeight: 105, alignment: .leading)
                .padding(12)
                .background(selected, in: RoundedRectangle(cornerRadius: 10))
                .nbThemeInspectorTarget(role)

            case .elevated, .elevatedHigh, .reportCard, .overlaySurface, .reportDropdown,
                 .controlFill, .controlFillStrong, .reportInteractiveFill, .reportSelectedFill,
                 .reportSuccessFill, .reportWarningFill, .reportDangerFill, .headingFill:
                Label("Filled \(role.displayName)", systemImage: "square.on.square")
                    .foregroundStyle(exampleText)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(selected, in: RoundedRectangle(cornerRadius: 12))
                    .nbThemeInspectorTarget(role)

            case .overlayScrim, .imageScrim, .mask:
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.gray.gradient)
                    Image(systemName: "photo.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.5))
                    if role == .imageScrim {
                        LinearGradient(colors: [.clear, selected], startPoint: .top, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .nbThemeInspectorTarget(role)
                    } else {
                        selected
                            .opacity(role == .mask ? 0.65 : 1)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .nbThemeInspectorTarget(role)
                    }
                    Text("Content behind \(role.displayName)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, minHeight: 112)

            case .shadow, .reportShadow:
                Text("Floating content")
                    .foregroundStyle(exampleText)
                    .padding(20)
                    .background(exampleSurface, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: selected, radius: 17, x: 0, y: 9)
                    .nbThemeInspectorTarget(role)
                    .padding(18)

            case .text, .textSecondary, .textTertiary, .disabledText, .onAccent, .overlayText,
                 .reportText, .reportDim, .reportSelectedText, .navigationText, .navigationTitle,
                 .segmentText, .segmentSelectedText, .searchText, .searchPlaceholder,
                 .liveActivityPrimaryText, .liveActivitySecondaryText, .liveActivityActionText:
                Text(role.displayName == "Search Placeholder" ? "Search for an app" : role.displayName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(selected)
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(role == .onAccent ? NBHalloween.accent : exampleSurface,
                                in: RoundedRectangle(cornerRadius: 10))
                    .nbThemeInspectorTarget(role)

            case .separator, .border, .imageBorder, .navigationShadow, .tabShadow,
                 .reportBorder, .reportInteractiveBorder:
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected, lineWidth: 3)
                    .frame(height: 80)
                    .overlay { Text("Outlined content").font(.caption).foregroundStyle(exampleText) }
                    .nbThemeInspectorTarget(role)

            case .tabBackground, .tabSelected, .tabUnselected:
                HStack(spacing: 24) {
                    Label("Library", systemImage: "square.grid.2x2.fill")
                        .foregroundStyle(role == .tabSelected ? selected : NBHalloween.color(.tabSelected))
                        .nbThemeInspectorTarget(.tabSelected)
                    Spacer(minLength: 0)
                    Label("Settings", systemImage: "gearshape")
                        .foregroundStyle(role == .tabUnselected ? selected : NBHalloween.color(.tabUnselected))
                        .nbThemeInspectorTarget(.tabUnselected)
                }
                .font(.caption)
                .padding(14)
                .background(role == .tabBackground ? selected : NBHalloween.color(.tabBackground),
                            in: RoundedRectangle(cornerRadius: 12))
                .nbThemeInspectorTarget(.tabBackground)

            case .searchBackground, .searchTint:
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("Search apps")
                    Spacer(minLength: 0)
                    Text("|")
                        .foregroundStyle(role == .searchTint ? selected : NBHalloween.color(.searchTint))
                        .nbThemeInspectorTarget(.searchTint)
                }
                .foregroundStyle(NBHalloween.color(.searchPlaceholder))
                .padding(14)
                .background(role == .searchBackground ? selected : NBHalloween.color(.searchBackground),
                            in: RoundedRectangle(cornerRadius: 12))
                .nbThemeInspectorTarget(.searchBackground)

            case .segmentBackground, .segmentSelectedBackground:
                HStack(spacing: 4) {
                    Text("Downloaded")
                        .foregroundStyle(NBHalloween.color(.segmentSelectedText))
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(role == .segmentSelectedBackground ? selected : NBHalloween.color(.segmentSelectedBackground),
                                    in: RoundedRectangle(cornerRadius: 9))
                        .nbThemeInspectorTarget(.segmentSelectedBackground)
                    Text("Signed")
                        .foregroundStyle(NBHalloween.color(.segmentText))
                        .padding(10)
                        .frame(maxWidth: .infinity)
                }
                .background(role == .segmentBackground ? selected : NBHalloween.color(.segmentBackground),
                            in: RoundedRectangle(cornerRadius: 12))
                .nbThemeInspectorTarget(.segmentBackground)

            case .navigationTint, .barButtonTint:
                Label(role == .navigationTint ? "Back" : "Edit",
                      systemImage: role == .navigationTint ? "chevron.left" : "ellipsis.circle")
                    .foregroundStyle(selected)
                    .padding(16)
                    .background(exampleSurface, in: RoundedRectangle(cornerRadius: 12))
                    .nbThemeInspectorTarget(role)

            case .navigationBackground:
                HStack {
                    Image(systemName: "square.grid.2x2.fill")
                    Text("Real control background")
                    Spacer()
                }
                .foregroundStyle(exampleText)
                .padding(14)
                .background(selected, in: RoundedRectangle(cornerRadius: 12))
                .nbThemeInspectorTarget(role)

            case .reportTapHighlight:
                Label("Pressed report row", systemImage: "hand.tap.fill")
                    .foregroundStyle(NBHalloween.color(.reportText))
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(NBHalloween.color(.reportCard), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(selected)
                            .nbThemeInspectorTarget(role)
                    }

            case .liveActivityBackground, .liveActivityRunning, .liveActivityIdle:
                HStack(spacing: 10) {
                    Circle()
                        .fill(role == .liveActivityBackground ? NBHalloween.liveActivityRunning : selected)
                        .frame(width: 13, height: 13)
                        .nbThemeInspectorTarget(role)
                    Text("Silent audio running")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(NBHalloween.liveActivityPrimaryText)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(role == .liveActivityBackground ? selected : NBHalloween.liveActivityBackground,
                            in: Capsule())
                .nbThemeInspectorTarget(role == .liveActivityBackground ? role : .liveActivityBackground)

            default:
                Label(role.displayName, systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(selected)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(exampleSurface, in: RoundedRectangle(cornerRadius: 12))
                    .nbThemeInspectorTarget(role)
            }
        }
        .padding(3)
    }
}

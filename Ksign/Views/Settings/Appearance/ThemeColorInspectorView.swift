//
//  ThemeColorInspectorView.swift
//  Ksign
//
//  Temporary color editing over a copy of the app screen where the color is
//  used, or a clearly labeled full-screen sample state when live content is
//  unavailable. Crypt Check and Live Activity have contextual previews.
//

import SwiftUI
import UIKit
import WebKit
import NimbleViews
import NimbleExtensions

struct ThemeColorInspectorView: View {
    let role: NBThemeRole
    let themeID: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var themes = NBThemeManager.shared
    @State private var didBeginPreview = false
    @State private var appearancePath = ["appearance"]
    @State private var sampleSegmentSelection = 0
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
            } else if role.category == .reports {
                ThemeCryptReportPreview(role: role, revision: themes.previewRevision)
            } else if role.category == .liveActivity {
                ThemeActivityContextPreview(role: role)
                    .environment(\.nbInspectedThemeRole, role)
            } else {
                ThemeAppContextPreview(role: role)
                    .environment(\.nbInspectedThemeRole, role)
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
            // A copy of the real tab container; visible content is live.
            VariedTabbarView(previewTab: .library)
        case .segmented:
            // The real Appearance picker is intentionally disabled. Use the
            // same native segmented control in an otherwise familiar Appearance
            // page, with a local, non-persisted selection so both text states
            // can be inspected without changing Ksign settings.
            NBNavigationView("Appearance") {
                NBList("Appearance") {
                    Section {
                        Label("Contextual sample of the Appearance segmented picker. This selection does not change app settings.",
                              systemImage: "eye")
                            .font(.caption)
                            .foregroundStyle(NBHalloween.textSecondary)
                    }
                    NBSection("Store Cell Appearance") {
                        Picker("Store Cell Appearance", selection: $sampleSegmentSelection) {
                            Text("Standard").tag(0)
                            Text("Big Description").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text("Choose how application rows are displayed.")
                            .font(.caption)
                            .foregroundStyle(NBHalloween.textSecondary)
                    }
                    NBSection("Theme") {
                        Label("Customize Colors", systemImage: "paintpalette")
                    }
                }
            }
        case .downloads:
            // Use the real Downloads screen, including its production IPA
            // Vault status row. If no download is active, the same row is
            // rendered with clearly labeled sample values (no network work).
            DownloaderView(inspectorSampleDownloadStatus: true)
        }
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
                    Text("This control isn't currently exposed on the copied screen. Scroll or reveal its search / toolbar controls above to find the highlighted element.")
                        .font(.caption)
                        .foregroundStyle(.yellow)
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

private enum InspectorRealScreen { case appearance, library, segmented, downloads }

private extension NBThemeRole {
    var usesRealScreen: Bool {
        switch self {
        case .background, .elevated, .text, .textSecondary, .textTertiary,
             .accent, .heading, .headingFill:
            return true
        default:
            return category == .navigation
        }
    }

    var realScreen: InspectorRealScreen {
        switch self {
        case .background, .elevated, .text, .textSecondary, .navigationTint, .navigationText:
            return .appearance
        case .textTertiary: return .downloads
        case .segmentBackground, .segmentSelectedBackground, .segmentText, .segmentSelectedText:
            return .segmented
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

// MARK: - Full-screen contextual states for colors that need sample content

// These are intentionally full Ksign-style pages, not isolated swatches. Each
// sample is identified as such. It never changes the user's downloads,
// certificates, files or install queue.
private struct ThemeAppContextPreview: View {
    let role: NBThemeRole
    @StateObject private var themes = NBThemeManager.shared

    private var screenTitle: String {
        switch role {
        case .warning, .mask: return "Downloads"
        case .disabledText, .danger, .expired, .success: return "Certificates"
        case .imageScrim, .overlayText, .imageBorder: return "Sources"
        case .overlaySurface, .overlayScrim, .shadow: return "Library"
        default: return "Library"
        }
    }

    private var sampleDescription: String {
        switch role {
        case .elevatedHigh, .controlFillStrong, .selection:
            return "This role has no app-screen usage in this revision. The page below demonstrates how it could look; editing it won't recolor an existing app control."
        case .title, .border:
            return "This role is currently used by the theme editor's preview. This example shows it beside the other library colors."
        case .secondaryAccent:
            return "The secondary accent is currently visible in the theme swatches. This is a contextual sample of an accent badge."
        default:
            return "Contextual sample state. The surrounding interface uses your active theme; no real content or operation has been changed."
        }
    }

    var body: some View {
        NBNavigationView(screenTitle) {
            NBList(screenTitle) {
                Section {
                    Label(sampleDescription, systemImage: "eye")
                        .font(.caption)
                        .foregroundStyle(NBHalloween.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                NBSection(sectionTitle, secondary: "2") {
                    primaryExample
                    secondaryRow
                }

                NBSection("Details") {
                    Label("Theme settings", systemImage: "paintpalette")
                    HStack {
                        Text("App appearance")
                        Spacer()
                        Text("Custom")
                            .foregroundStyle(NBHalloween.textSecondary)
                    }
                }
            }
        }
    }

    private var sectionTitle: String {
        switch role {
        case .warning, .mask: return "Downloading"
        case .disabledText, .danger, .expired, .success: return "Certificates"
        case .imageScrim, .overlayText, .imageBorder: return "News"
        case .overlaySurface, .overlayScrim, .shadow: return "Install Queue"
        default: return "Applications"
        }
    }

    private var secondaryRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(NBHalloween.accent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text("Other application").foregroundStyle(NBHalloween.text)
                Text("Ready in your library")
                    .font(.caption)
                    .foregroundStyle(NBHalloween.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(NBHalloween.textSecondary)
                .font(.caption)
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var primaryExample: some View {
        switch role {
        case .imageScrim, .overlayText, .imageBorder:
            newsContext
        case .overlaySurface, .overlayScrim, .shadow:
            installDrawerContext
        case .mask:
            maskedArtworkContext
        case .warning:
            downloadContext
        case .disabledText:
            HStack {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(NBHalloween.textSecondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sign with certificate").foregroundStyle(NBHalloween.text)
                    Text("No certificate selected")
                        .font(.caption)
                        .foregroundStyle(NBHalloween.disabledText)
                        .nbThemeInspectorTarget(.disabledText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(NBHalloween.disabledText)
                    .nbThemeInspectorTarget(.disabledText)
            }
            .padding(.vertical, 6)
        case .danger:
            Label("Revoke selected certificate", systemImage: "xmark.octagon.fill")
                .foregroundStyle(NBHalloween.danger)
                .nbThemeInspectorTarget(.danger)
                .padding(.vertical, 8)
        case .expired:
            HStack {
                Label("Certificate expired", systemImage: "calendar.badge.exclamationmark")
                    .foregroundStyle(NBHalloween.expired)
                    .nbThemeInspectorTarget(.expired)
                Spacer()
                Text("Expired")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(NBHalloween.expired)
            }
            .padding(.vertical, 8)
        case .success:
            HStack {
                Label("Certificate verified", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(NBHalloween.text)
                Spacer()
                Text("Valid")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(NBHalloween.ok)
                    .nbThemeInspectorTarget(.success)
            }
            .padding(.vertical, 8)
        case .onAccent:
            HStack {
                appIcon
                appInfo
                Spacer()
                Text("Install")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NBHalloween.onAccent)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(NBHalloween.accent, in: Capsule())
                    .nbThemeInspectorTarget(.onAccent)
            }
        case .secondaryAccent:
            HStack {
                appIcon
                appInfo
                Spacer()
                Text("Pending")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(NBHalloween.pumpkin)
                    .nbThemeInspectorTarget(.secondaryAccent)
            }
        case .tertiaryAccent:
            HStack {
                appIcon
                appInfo
                Spacer()
                Image(systemName: "circle.dotted.circle.fill")
                    .foregroundStyle(NBHalloween.neonPurple)
                    .nbThemeInspectorTarget(.tertiaryAccent)
                Text("Queued")
                    .font(.caption)
                    .foregroundStyle(NBHalloween.textSecondary)
            }
        case .separator:
            VStack(alignment: .leading, spacing: 10) {
                appRow
                Rectangle()
                    .fill(NBHalloween.hairline)
                    .frame(height: 2)
                    .nbThemeInspectorTarget(.separator)
                Label("App details", systemImage: "info.circle")
                    .foregroundStyle(NBHalloween.textSecondary)
            }
            .padding(.vertical, 8)
        case .elevatedHigh:
            HStack { appIcon; appInfo; Spacer() }
                .padding(14)
                .background(NBHalloween.elevatedHigh, in: RoundedRectangle(cornerRadius: 14))
                .nbThemeInspectorTarget(.elevatedHigh)
                .padding(.vertical, 3)
        case .controlFillStrong:
            HStack {
                appInfo
                Spacer()
                Image(systemName: "checkmark")
                    .foregroundStyle(NBHalloween.text)
                    .frame(width: 40, height: 38)
                    .background(NBHalloween.controlFillStrong, in: RoundedRectangle(cornerRadius: 9))
                    .nbThemeInspectorTarget(.controlFillStrong)
            }
        case .title:
            VStack(alignment: .leading, spacing: 6) {
                Text("Your Library")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(NBHalloween.title)
                    .nbThemeInspectorTarget(.title)
                appRow
            }
        case .selection:
            HStack {
                appIcon
                appInfo
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(NBHalloween.selection)
                    .nbThemeInspectorTarget(.selection)
            }
        case .border:
            HStack { appIcon; appInfo; Spacer() }
                .padding(12)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(NBHalloween.border, lineWidth: 2)
                        .nbThemeInspectorTarget(.border)
                }
        case .controlFill:
            HStack { appIcon; appInfo; Spacer() }
        default:
            appRow
        }
    }

    private var appIcon: some View {
        Image(systemName: "shippingbox.fill")
            .font(.title2)
            .foregroundStyle(NBHalloween.accent)
            .frame(width: 44, height: 44)
            .background(NBHalloween.controlFill, in: RoundedRectangle(cornerRadius: 11))
            .nbThemeInspectorTarget(.controlFill)
    }

    private var appInfo: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Example App")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(NBHalloween.text)
            Text("Ready to install")
                .font(.caption)
                .foregroundStyle(NBHalloween.textSecondary)
        }
    }

    private var appRow: some View {
        HStack(spacing: 12) { appIcon; appInfo; Spacer() }
            .padding(.vertical, 5)
    }

    private var downloadContext: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.document")
                .font(.title2)
                .foregroundStyle(NBHalloween.accent)
            VStack(alignment: .leading, spacing: 8) {
                Text("Example.ipa").foregroundStyle(NBHalloween.text)
                Text("62 MB / 100 MB (62%)")
                    .font(.caption)
                    .foregroundStyle(NBHalloween.textSecondary)
                ProgressView(value: 0.62)
                    .tint(NBHalloween.warning)
                    .nbThemeInspectorTarget(.warning)
            }
            Spacer(minLength: 0)
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(NBHalloween.warning)
                .nbThemeInspectorTarget(.warning)
        }
        .padding(.vertical, 6)
    }

    private var newsContext: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(NBHalloween.controlFill)
                    .overlay {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(NBHalloween.accent.opacity(0.35))
                    }
                LinearGradient(colors: [.clear, NBHalloween.imageScrim],
                               startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .nbThemeInspectorTarget(.imageScrim)
                Text("New applications in Sources")
                    .font(.headline)
                    .foregroundStyle(NBHalloween.overlayText)
                    .nbThemeInspectorTarget(.overlayText)
                    .padding(16)
            }
            .frame(height: 150)
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(NBHalloween.imageBorder, lineWidth: 1.5)
                    .nbThemeInspectorTarget(.imageBorder)
            }
            Text("News card · sample artwork")
                .font(.caption)
                .foregroundStyle(NBHalloween.textSecondary)
        }
        .padding(.vertical, 5)
    }

    private var maskedArtworkContext: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13)
                .fill(NBHalloween.controlFill)
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 60))
                .foregroundStyle(NBHalloween.accent)
            LinearGradient(colors: [.clear, NBHalloween.mask],
                           startPoint: .top, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .nbThemeInspectorTarget(.mask)
            VStack {
                Spacer()
                Text("Download preview")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(NBHalloween.overlayText)
                    .padding(12)
            }
        }
        .frame(height: 140)
        .padding(.vertical, 5)
    }

    private var installDrawerContext: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 9) {
                appRow
                Divider()
                Label("Install options", systemImage: "square.and.arrow.down")
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(NBHalloween.elevated, in: RoundedRectangle(cornerRadius: 14))

            NBHalloween.overlayScrim
                .nbThemeInspectorTarget(.overlayScrim)

            VStack(alignment: .leading, spacing: 8) {
                Text("Install Queue").font(.headline)
                Text("1 application is ready")
                    .font(.caption)
                    .foregroundStyle(NBHalloween.textSecondary)
                HStack {
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(NBHalloween.accent)
                    Text("Example App")
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(NBHalloween.ok)
                }
                .padding(.top, 7)
            }
            .padding(18)
            .background(NBHalloween.overlaySurface, in: RoundedRectangle(cornerRadius: 14))
            .nbThemeInspectorTarget(.overlaySurface)
            .shadow(color: NBHalloween.shadow, radius: 16, y: 7)
            .nbThemeInspectorTarget(.shadow)
            .padding(15)
        }
        .frame(height: 225)
    }
}
// MARK: - Lock Screen / Dynamic Island context (widget extension sample)

private struct ThemeActivityContextPreview: View {
    let role: NBThemeRole
    @State private var running: Bool
    @StateObject private var themes = NBThemeManager.shared

    init(role: NBThemeRole) {
        self.role = role
        _running = State(initialValue: role != .liveActivityIdle)
    }

    private var statusColor: Color {
        running ? NBHalloween.liveActivityRunning : NBHalloween.liveActivityIdle
    }

    var body: some View {
        NBNavigationView("Live Activity") {
            NBList("Live Activity") {
                Section {
                    Label("Widget extension preview · sample state. iOS owns the actual Lock Screen and Dynamic Island presentation.",
                          systemImage: "eye")
                        .font(.caption)
                        .foregroundStyle(NBHalloween.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                NBSection("Lock Screen") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(running ? "Silent audio running" : "Silent audio paused")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(NBHalloween.liveActivityPrimaryText)
                                .nbThemeInspectorTarget(.liveActivityPrimaryText)
                            Spacer(minLength: 6)
                            Text("00:24")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(NBHalloween.liveActivitySecondaryText)
                                .nbThemeInspectorTarget(.liveActivitySecondaryText)
                        }
                        ProgressView(value: 0.62)
                            .tint(statusColor)
                        HStack(spacing: 8) {
                            Image(systemName: running ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .foregroundStyle(statusColor)
                                .nbThemeInspectorTarget(running ? .liveActivityRunning : .liveActivityIdle)
                            Text(running ? "Awake" : "Not awake")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(NBHalloween.liveActivityPrimaryText)
                            Spacer()
                            Text("Keep Alive")
                                .font(.caption)
                                .foregroundStyle(NBHalloween.liveActivitySecondaryText)
                        }
                        HStack {
                            Text("Ksign keeps this session available")
                                .font(.caption2)
                                .foregroundStyle(NBHalloween.liveActivitySecondaryText)
                            Spacer()
                            Text(running ? "Pause" : "Resume")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(NBHalloween.liveActivityActionText)
                                .nbThemeInspectorTarget(.liveActivityActionText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(statusColor.opacity(0.26), in: Capsule())
                        }
                    }
                    .padding(17)
                    .background(NBHalloween.liveActivityBackground,
                                in: RoundedRectangle(cornerRadius: 17))
                    .nbThemeInspectorTarget(.liveActivityBackground)
                    .padding(.vertical, 6)
                }

                NBSection("Dynamic Island") {
                    HStack(spacing: 12) {
                        Image(systemName: running ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .foregroundStyle(statusColor)
                            .nbThemeInspectorTarget(running ? .liveActivityRunning : .liveActivityIdle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(running ? "Awake" : "Not awake")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(NBHalloween.liveActivityPrimaryText)
                            Text("00:24 · Keep Alive")
                                .font(.caption2)
                                .foregroundStyle(NBHalloween.liveActivitySecondaryText)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .background(Color.black, in: Capsule())
                    .padding(.vertical, 6)
                }

                NBSection("Sample state") {
                    Toggle("Audio running", isOn: $running)
                        .tint(NBHalloween.accent)
                }
            }
        }
    }
}
// MARK: - Crypt Check's HTML layout, with harmless sample report data

// The HTML uses the same CSS role names, colors and major layout elements as
// CryptCheckAnalyzer.makeHTML. It is an interactive sample report, not an IPA
// scan; WKWebView CSS custom properties update without reloading while a
// slider is dragged, so scroll position and context stay intact.
private struct ThemeCryptReportPreview: UIViewRepresentable {
    let role: NBThemeRole
    let revision: UInt64

    private static let cssRoles: [(String, NBThemeRole)] = [
        ("bg", .reportBackground), ("card", .reportCard),
        ("border", .reportBorder), ("text", .reportText),
        ("dim", .reportDim), ("cyan", .reportAccent),
        ("green", .reportSuccess), ("orange", .reportWarning),
        ("red", .reportDanger), ("green-fill", .reportSuccessFill),
        ("orange-fill", .reportWarningFill), ("red-fill", .reportDangerFill),
        ("tap-highlight", .reportTapHighlight), ("pink", .reportPink),
        ("purple", .reportPurple), ("blue", .reportBlue),
        ("lime", .reportLime), ("interactive-fill", .reportInteractiveFill),
        ("interactive-border", .reportInteractiveBorder),
        ("selected-fill", .reportSelectedFill),
        ("selected-text", .reportSelectedText),
        ("dropdown", .reportDropdown), ("shadow", .reportShadow)
    ]

    private static func cssVariables() -> String {
        cssRoles.map { name, role in
            "--\(name):\(NBThemeManager.shared.activeColor(for: role).cssRGBA);"
        }.joined()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.isOpaque = false
        view.backgroundColor = NBHalloween.uiColor(.reportBackground)
        view.scrollView.backgroundColor = NBHalloween.uiColor(.reportBackground)
        view.navigationDelegate = context.coordinator
        context.coordinator.role = role
        view.loadHTMLString(Self.sampleHTML, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.role = role
        view.backgroundColor = NBHalloween.uiColor(.reportBackground)
        view.scrollView.backgroundColor = NBHalloween.uiColor(.reportBackground)
        context.coordinator.update(view, variables: Self.cssVariables())
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var role: NBThemeRole = .reportBackground
        private var loaded = false
        private var hasScrolledToTarget = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            update(webView, variables: ThemeCryptReportPreview.cssVariables())
        }

        func update(_ webView: WKWebView, variables: String) {
            guard loaded else { return }
            let selector = "[data-role~='\(role.rawValue)']"
            let script = """
            document.documentElement.style.cssText = \(String(reflecting: variables));
            document.querySelectorAll('.inspected').forEach(function(el) {
              el.classList.remove('inspected');
            });
            var target = document.querySelector(\(String(reflecting: selector)));
            if (target) {
              target.classList.add('inspected');
              \(hasScrolledToTarget ? "" : "target.scrollIntoView({block: 'center', behavior: 'auto'});")
            }
            """
            webView.evaluateJavaScript(script, completionHandler: nil)
            hasScrolledToTarget = true
        }
    }

    private static var sampleHTML: String {
        """
        <!doctype html><html lang="en"><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <style>
        :root { color-scheme: dark; \(cssVariables()) }
        * { box-sizing:border-box; }
        body { margin:0;padding:22px 16px 400px;background:var(--bg);color:var(--text);
          font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',sans-serif; }
        .inspected { outline:3px solid #ffdc34 !important;outline-offset:3px;
          box-shadow:0 0 0 5px rgba(0,0,0,.55);border-radius:6px; }
        .notice {border:1px solid var(--interactive-border);background:var(--interactive-fill);
          color:var(--dim);border-radius:10px;padding:10px 12px;font-size:.72rem;margin-bottom:18px;}
        .header {position:relative;border-bottom:1px solid var(--border);padding-bottom:18px;margin-bottom:18px;}
        h1 {margin:0;font:700 1.3rem ui-monospace,Menlo,monospace;color:var(--cyan);}
        .sub {color:var(--dim);font-size:.78rem;margin-top:5px;}
        .source {color:var(--text);font-size:.86rem;margin-top:8px;}
        .summary {display:grid;grid-template-columns:repeat(2,1fr);gap:10px;margin-bottom:22px;}
        .stat {position:relative;text-align:center;padding:14px 9px;border-radius:14px;
          background:linear-gradient(180deg,var(--interactive-fill),var(--card));
          border:1px solid var(--border);-webkit-tap-highlight-color:var(--tap-highlight);}
        .num {font:700 1.55rem ui-monospace,Menlo,monospace;line-height:1;}
        .lbl {color:var(--dim);font-size:.68rem;text-transform:uppercase;margin-top:6px;}
        .green {color:var(--green)} .orange {color:var(--orange)} .red {color:var(--red)}
        .card {background:var(--card);border:1px solid var(--border);border-radius:13px;
          padding:18px 15px;margin-bottom:17px;box-shadow:0 10px 24px var(--shadow);}
        .card-head {font:700 .84rem ui-monospace,Menlo,monospace;}
        .meta {font:.72rem ui-monospace,Menlo,monospace;color:var(--dim);margin:8px 0 11px;}
        .tag {display:inline-block;font:700 .81rem ui-monospace,Menlo,monospace;
          padding:5px 10px;border-radius:7px;margin:4px 6px 8px 0;}
        .ok {color:var(--green);background:var(--green-fill)}
        .warn {color:var(--orange);background:var(--orange-fill)}
        .bad {color:var(--red);background:var(--red-fill)}
        .filter {border:1px solid var(--interactive-border);background:var(--interactive-fill);
          color:var(--dim);border-radius:100px;padding:6px 11px;font-size:.7rem;}
        .filter.selected {color:var(--selected-text);background:var(--selected-fill);}
        .dropdown {border:1px solid var(--interactive-border);background:var(--dropdown);
          border-radius:13px;padding:13px;margin:12px 0;box-shadow:0 10px 22px var(--shadow);}
        .op {font:700 .8rem ui-monospace,Menlo,monospace;margin-right:11px;}
        .pink {color:var(--pink)} .purple {color:var(--purple)}
        .blue {color:var(--blue)} .lime {color:var(--lime)}
        .tap {background:var(--tap-highlight);border-radius:7px;padding:10px;font-size:.75rem;margin-top:10px;}
        </style></head>
        <body data-role="reportBackground">
          <div class="notice">Crypt Check · contextual sample report. No IPA was scanned; saved colors apply to newly generated reports.</div>
          <header class="header">
            <h1 data-role="reportAccent">🔐 cryptcheck</h1>
            <div class="sub" data-role="reportDim">Example report · sample status</div>
            <div class="source" data-role="reportText">Example.app / ExampleBinary</div>
          </header>
          <div class="summary">
            <div class="stat" data-role="reportInteractiveFill">
              <div class="num" data-role="reportText">3</div><div class="lbl" data-role="reportDim">Binaries</div>
            </div>
            <div class="stat"><div class="num green" data-role="reportSuccess">2</div><div class="lbl">Decrypted</div></div>
            <div class="stat"><div class="num red" data-role="reportDanger">0</div><div class="lbl">Encrypted</div></div>
            <div class="stat"><div class="num orange" data-role="reportWarning">1</div><div class="lbl">Likely enc</div></div>
          </div>
          <section class="card" data-role="reportCard reportBorder reportShadow">
            <div class="card-head" data-role="reportText">ExampleBinary · arm64</div>
            <div class="meta" data-role="reportDim">2.4 MB &nbsp; | &nbsp; LC_ENCRYPTION_INFO_64</div>
            <span class="tag ok" data-role="reportSuccessFill">Decrypted</span>
            <span class="tag warn" data-role="reportWarningFill">Review</span>
            <span class="tag bad" data-role="reportDangerFill">Encrypted</span>
            <div class="meta">Inspection filters</div>
            <button type="button" class="filter selected" data-role="reportSelectedFill reportSelectedText">All</button>
            <button type="button" class="filter" data-role="reportInteractiveFill reportInteractiveBorder">Decrypted</button>
            <button type="button" class="filter">Encrypted</button>
            <div class="dropdown" data-role="reportDropdown">
              <div class="meta">Filter menu · sample entries</div>
              <div class="source">▸ ExampleBinary</div>
              <div class="source">▸ ExampleFramework.dylib</div>
            </div>
            <div class="card-head">Instruction sample</div>
            <p><span class="op pink" data-role="reportPink">CBZ</span>
              <span class="op purple" data-role="reportPurple">MOV</span>
              <span class="op blue" data-role="reportBlue">ADD</span>
              <span class="op lime" data-role="reportLime">RET</span></p>
            <div class="tap" data-role="reportTapHighlight">Tap-highlight example · report row pressed</div>
          </section>
          <section class="card"><div class="card-head">ExampleFramework.dylib</div>
            <div class="meta">Additional sample report section</div>
            <span class="tag ok">Decrypted</span>
          </section>
        </body></html>
        """
    }
}

//
//  ThemeEditingOverlay.swift
//  Ksign
//
//  Presentation-aware, in-place theme editor. The editor lives in its own
//  transparent UIWindow above the app's active UIWindowScene, so the same
//  paintbrush follows the user into sheets, full-screen covers, nested modal
//  presentations, and navigation stacks without recreating those screens.
//

import SwiftUI
import UIKit
import WebKit
import NimbleViews
import NimbleExtensions

// MARK: - Root installer

struct ThemeEditingRoot<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background {
                ThemeEditingWindowInstaller()
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

private struct ThemeEditingWindowInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> ThemeEditingWindowInstallerView {
        let view = ThemeEditingWindowInstallerView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: ThemeEditingWindowInstallerView, context: Context) {
        uiView.scheduleInstall()
    }
}

private final class ThemeEditingWindowInstallerView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleInstall()
    }

    func scheduleInstall() {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            ThemeEditingOverlayWindowManager.shared.install(over: window)
        }
    }
}

private final class ThemeEditingOverlayWindowManager: NSObject {
    static let shared = ThemeEditingOverlayWindowManager()

    private var overlayWindows: [ObjectIdentifier: ThemeEditingOverlayWindow] = [:]

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDisconnected),
                                               name: UIScene.didDisconnectNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDeactivated),
                                               name: UIScene.willDeactivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneActivated),
                                               name: UIScene.didActivateNotification, object: nil)
    }

    @objc private func sceneDisconnected(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene,
              let window = overlayWindows.removeValue(forKey: ObjectIdentifier(scene)) else { return }
        window.coordinator.endEditingSession()
        window.isHidden = true
        window.rootViewController = nil
    }

    @objc private func sceneDeactivated(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene,
              let window = overlayWindows[ObjectIdentifier(scene)] else { return }
        window.isHidden = true
    }

    @objc private func sceneActivated(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene,
              let window = overlayWindows[ObjectIdentifier(scene)] else { return }
        window.isHidden = false
    }

    func install(over baseWindow: UIWindow) {
        guard let scene = baseWindow.windowScene else { return }
        let key = ObjectIdentifier(scene)

        if let existing = overlayWindows[key] {
            if existing.baseWindow !== baseWindow {
                existing.coordinator.endEditingSession()
                existing.baseWindow = baseWindow
                let controller = UIHostingController(rootView: ThemeEditingOverlayWindowView(
                    baseWindow: baseWindow, coordinator: existing.coordinator
                ))
                controller.view.backgroundColor = .clear
                existing.rootViewController = controller
            }
            return
        }

        let overlayWindow = ThemeEditingOverlayWindow(windowScene: scene)
        overlayWindow.baseWindow = baseWindow
        overlayWindow.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 2)
        overlayWindow.backgroundColor = .clear

        let controller = UIHostingController(
            rootView: ThemeEditingOverlayWindowView(baseWindow: baseWindow, coordinator: overlayWindow.coordinator)
        )
        controller.view.backgroundColor = .clear
        overlayWindow.rootViewController = controller
        overlayWindow.isHidden = scene.activationState != .foregroundActive
        overlayWindows[key] = overlayWindow
    }
}

private final class ThemeEditingOverlayWindow: UIWindow {
    weak var baseWindow: UIWindow?
    let coordinator = ThemeEditingCoordinator()

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Picking intentionally consumes the whole screen so selecting a real
        // control never also triggers the control underneath it. If a system
        // presentation (ColorPicker/confirmation dialog) belongs to this
        // overlay, let that presentation handle its entire surface as well.
        if coordinator.isPicking || coordinator.editingRole != nil || rootViewController?.presentedViewController != nil {
            return super.hitTest(point, with: event) ?? rootViewController?.view ?? self
        }

        // Outside the paintbrush/editor panels this window is transparent to
        // interaction, so the app underneath behaves normally.
        guard coordinator.interactiveFrames.contains(where: { $0.contains(point) }) else {
            return nil
        }
        return super.hitTest(point, with: event)
    }
}

// MARK: - Scene editor state

private struct ThemeEditingCandidate: Identifiable, Equatable {
    let role: NBThemeRole
    let elementID: String?
    /// Exact targets may render a transformed role color (for example Accent at
    /// 16% opacity). This is the no-local-override color the editor should open
    /// on before a local override is created.
    let initialColor: NBThemeColor?

    init(role: NBThemeRole, elementID: String?, initialColor: NBThemeColor? = nil) {
        self.role = role
        self.elementID = elementID
        self.initialColor = initialColor
    }

    var id: String { "\(role.rawValue)|\(elementID ?? "role")" }
    var isExactElement: Bool { elementID != nil }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.role == rhs.role && lhs.elementID == rhs.elementID
    }
}

private final class ThemeEditingCoordinator: ObservableObject, @unchecked Sendable {
    @Published var isEditingTheme = false
    @Published var editingRole: NBThemeRole?
    @Published var editingElementID: String?
    private var editingThemeID: String?
    @Published var originalColor: NBThemeColor?
    @Published var candidateTargets: [ThemeEditingCandidate] = []
    @Published var showDuplicatePrompt = false
    @Published var dockEditorAtTop = false
    @Published var compactEditor = false
    @Published var showMissHint = false

    // Read synchronously by ThemeEditingOverlayWindow.hitTest.
    var interactiveFrames: [CGRect] = []

    var isPicking: Bool {
        isEditingTheme && editingRole == nil
    }

    private let themes = NBThemeManager.shared

    init() {}

    func beginEditing() {
        if themes.isActiveThemeBuiltIn {
            showDuplicatePrompt = true
        } else {
            withAnimation(.snappy) { isEditingTheme = true }
        }
    }

    func duplicateAndBeginEditing() {
        _ = themes.duplicateActiveTheme()
        withAnimation(.snappy) { isEditingTheme = true }
    }

    func select(_ candidate: ThemeEditingCandidate) {
        guard isPicking, !themes.isActiveThemeBuiltIn else { return }
        let role = candidate.role
        editingThemeID = themes.selectedThemeID
        candidateTargets = []
        let profile = themes.profile(id: themes.selectedThemeID) ?? .halloween
        originalColor = candidate.elementID.flatMap { profile.elementOverride(for: $0) }
            ?? candidate.initialColor
            ?? profile.color(for: role)

        // Set selection identity first. isPicking becomes false immediately,
        // which removes every yellow discovery marker before preview begins.
        editingElementID = candidate.elementID
        editingRole = role
        themes.beginColorPreview(
            for: role,
            elementID: candidate.elementID,
            initialColor: candidate.initialColor,
            in: themes.selectedThemeID
        )
    }

    func finishRole(save: Bool) {
        guard let role = editingRole, let themeID = editingThemeID else { return }
        themes.endColorPreview(for: role, in: themeID, save: save)
        editingThemeID = nil
        editingRole = nil
        editingElementID = nil
        originalColor = nil
        candidateTargets = []
    }

    func endEditingSession() {
        if let role = editingRole, let themeID = editingThemeID {
            themes.endColorPreview(for: role, in: themeID, save: false)
        }
        editingThemeID = nil
        editingRole = nil
        editingElementID = nil
        originalColor = nil
        candidateTargets = []
        withAnimation(.snappy) { isEditingTheme = false }
    }

    func validateSession() {
        if let role = editingRole, let themeID = editingThemeID,
           !themes.isPreviewing(role, in: themeID) || themes.selectedThemeID != themeID {
            endEditingSession()
        } else if isEditingTheme && themes.isActiveThemeBuiltIn {
            endEditingSession()
        }
    }

    func presentTargets(_ candidates: [ThemeEditingCandidate]) {
        let unique = candidates.reduce(into: [ThemeEditingCandidate]()) { result, candidate in
            if !result.contains(candidate) { result.append(candidate) }
        }

        guard !unique.isEmpty else {
            candidateTargets = []
            withAnimation(.easeOut(duration: 0.12)) { showMissHint = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                withAnimation(.easeIn(duration: 0.15)) { self?.showMissHint = false }
            }
            return
        }

        showMissHint = false
        if unique.count == 1, let candidate = unique.first {
            select(candidate)
        } else {
            candidateTargets = unique
        }
    }

    func presentRoles(_ roles: [NBThemeRole]) {
        presentTargets(roles.map { ThemeEditingCandidate(role: $0, elementID: nil) })
    }

    func removeCurrentElementOverride() {
        guard let role = editingRole,
              let themeID = editingThemeID,
              let elementID = editingElementID else { return }
        themes.endColorPreview(for: role, in: themeID, save: false)
        themes.clearElementOverride(elementID, in: themeID)
        editingThemeID = nil
        editingRole = nil
        editingElementID = nil
        originalColor = nil
        candidateTargets = []
    }
}

// MARK: - Overlay UI

private struct ThemeEditingOverlayWindowView: View {
    let baseWindow: UIWindow

    @ObservedObject var coordinator: ThemeEditingCoordinator
    @StateObject private var themes = NBThemeManager.shared
    @StateObject private var registry = NBThemeInspectorRegistry.shared

    @State private var geometryRevision: UInt64 = 0
    @State private var inspectionRequest = UUID()
    @State private var presentationID: ObjectIdentifier?
    private let geometryTimer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        // Scrolling, UIKit presentations and animations do not necessarily
        // cause the SwiftUI target anchors to lay out again.
        let _ = geometryRevision
        let selecting = coordinator.isPicking
        GeometryReader { geometry in
            let presentationRoot = selecting ? currentPresentationRoot(in: baseWindow) : nil
            let swiftTargets = presentationRoot.map {
                registry.visibleTargets(in: baseWindow, within: $0)
            } ?? []
            let nativeTargets = presentationRoot.map {
                ThemeUIKitTargetDiscovery.targets(in: $0, window: baseWindow)
            } ?? []
            let allTargets = normalizedTargets(swiftTargets + nativeTargets, visibleIn: baseWindow.bounds)
            let reportWebViews = presentationRoot.map {
                ThemeReportBridge.shared.visibleWebViews(in: baseWindow, within: $0)
            } ?? []

            ZStack {
                if coordinator.editingRole != nil {
                    // Keep the underlying screen visually pristine but prevent
                    // accidental navigation/actions while a color transaction
                    // is active. The editor panel remains the only interactive
                    // control until Save or Cancel.
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                }

                if coordinator.isPicking {
                    discoveryMarkers(for: allTargets)
                    reportSurfaceMarkers(for: reportWebViews)

                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    let movement = abs(value.translation.width) + abs(value.translation.height)
                                    guard movement < 18 else { return }
                                    pickTarget(at: value.location)
                                }
                        )
                        .ignoresSafeArea()
                }

                if coordinator.isPicking {
                    pickingBanner(
                        targetCount: allTargets.count + reportWebViews.count,
                        safeAreaTop: baseWindow.safeAreaInsets.top
                    )
                } else if !coordinator.isEditingTheme {
                    editButton(bottomInset: baseWindow.safeAreaInsets.bottom)
                }

                if coordinator.isPicking, !coordinator.candidateTargets.isEmpty {
                    roleChooser(bottomInset: baseWindow.safeAreaInsets.bottom)
                }

                if let role = coordinator.editingRole {
                    colorEditor(for: role, safeInsets: EdgeInsets(top: baseWindow.safeAreaInsets.top, leading: 0, bottom: baseWindow.safeAreaInsets.bottom, trailing: 0))
                }

                if coordinator.isPicking, coordinator.showMissHint {
                    Text("No registered theme paint at this point")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.82), in: Capsule())
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .onReceive(geometryTimer) { _ in
            if coordinator.isPicking {
                let currentID = currentPresentationRoot(in: baseWindow).map(ObjectIdentifier.init)
                if presentationID != currentID {
                    presentationID = currentID
                    inspectionRequest = UUID()
                    coordinator.candidateTargets = []
                }
                geometryRevision &+= 1
            }
        }
        .onChange(of: themes.selectedThemeID) { _ in coordinator.validateSession() }
        .onChange(of: themes.previewRevision) { _ in coordinator.validateSession() }
        .onPreferenceChange(ThemeOverlayHitRegionPreferenceKey.self) { frames in
            coordinator.interactiveFrames = frames
        }
        .confirmationDialog(
            "Duplicate Halloween to edit?",
            isPresented: $coordinator.showDuplicatePrompt,
            titleVisibility: .visible
        ) {
            Button("Duplicate & Edit") {
                coordinator.duplicateAndBeginEditing()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Halloween is the built-in default and is read-only. A custom copy will be created and selected before theme editing begins.")
        }
    }

    private func normalizedTargets(
        _ targets: [NBThemeInspectorTargetFrame],
        visibleIn root: CGRect
    ) -> [NBThemeInspectorTargetFrame] {
        // Registration identity and paint ownership must survive until the
        // point-specific selector. Equal frames/roles do NOT imply equal paint.
        targets.filter {
            $0.frame.width > 0 && $0.frame.height > 0 &&
            $0.frame.minX.isFinite && $0.frame.minY.isFinite &&
            $0.frame.width.isFinite && $0.frame.height.isFinite &&
            $0.frame.intersects(root)
        }
    }

    @ViewBuilder
    private func discoveryMarkers(for targets: [NBThemeInspectorTargetFrame]) -> some View {
        ForEach(Array(targets.filter(\.isEditable).enumerated()), id: \.offset) { _, target in
            RoundedRectangle(cornerRadius: min(8, max(3, min(target.frame.width, target.frame.height) * 0.18)))
                .strokeBorder(.yellow.opacity(0.82), lineWidth: 2)
                .shadow(color: .black.opacity(0.55), radius: 1.5)
                .frame(width: max(2, target.frame.width), height: max(2, target.frame.height))
                .position(x: target.frame.midX, y: target.frame.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func reportSurfaceMarkers(for webViews: [WKWebView]) -> some View {
        ForEach(Array(webViews.enumerated()), id: \.offset) { _, webView in
            let frame = ThemeReportBridge.shared.frame(of: webView, in: baseWindow)
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.yellow.opacity(0.62), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func editButton(bottomInset: CGFloat) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    coordinator.beginEditing()
                } label: {
                    Image(systemName: "paintbrush.pointed.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(.black.opacity(0.78), in: Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1) }
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit Theme")
                .themeOverlayHitRegion()
                .padding(.trailing, 14)
                .padding(.bottom, max(82, bottomInset + 68))
            }
        }
    }

    private func pickingBanner(targetCount: Int, safeAreaTop: CGFloat) -> some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "paintbrush.pointed.fill")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Theme Edit")
                        .font(.subheadline.weight(.bold))
                    Text(targetCount == 0
                         ? "Tap any visible themed color"
                         : "Tap a themed element · choose this paint or its role")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 8)
                Button("Done") { coordinator.endEditingSession() }
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(0.2), lineWidth: 1)
            }
            .padding(.horizontal, 12)
            .padding(.top, max(8, safeAreaTop + 6))
            Spacer()
        }
    }

    private func roleChooser(bottomInset: CGFloat) -> some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Choose what to edit")
                        .font(.headline)
                    Spacer()
                    Button {
                        coordinator.candidateTargets = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .buttonStyle(.plain)
                }

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(coordinator.candidateTargets) { candidate in
                            let role = candidate.role
                            let swatch = candidate.elementID.flatMap {
                                themes.activeTheme.elementOverride(for: $0)
                            } ?? candidate.initialColor ?? themes.activeColor(for: role)
                            Button {
                                coordinator.select(candidate)
                            } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(swatch.color)
                                        .frame(width: 24, height: 24)
                                        .overlay { Circle().stroke(.white.opacity(0.3), lineWidth: 1) }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.isExactElement ? "This Element" : "All \(role.displayName)")
                                            .font(.subheadline.weight(.semibold))
                                        Text(candidate.isExactElement
                                             ? "Only this paint · currently uses \(role.displayName)"
                                             : role.usageDescription)
                                            .font(.caption2)
                                            .foregroundStyle(.white.opacity(0.64))
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                .foregroundStyle(.white)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
            .padding(14)
            .background(.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.45), radius: 15)
            .padding(.horizontal, 12)
            .padding(.bottom, max(14, bottomInset + 8))
            .themeOverlayHitRegion()
        }
    }

    @ViewBuilder
    private func colorEditor(for role: NBThemeRole, safeInsets: EdgeInsets) -> some View {
        VStack {
            if !coordinator.dockEditorAtTop { Spacer(minLength: 0) }
            editorPanel(for: role)
                .frame(maxWidth: 540)
                .padding(.horizontal, 12)
                .padding(.top, coordinator.dockEditorAtTop ? max(12, safeInsets.top + 8) : 0)
                .padding(.bottom, coordinator.dockEditorAtTop ? 0 : max(14, safeInsets.bottom + 8))
                .themeOverlayHitRegion()
            if coordinator.dockEditorAtTop { Spacer(minLength: 0) }
        }
    }

    private func editorPanel(for role: NBThemeRole) -> some View {
        let current = currentEditingColor(for: role)
        let isExactElement = coordinator.editingElementID != nil

        return VStack(alignment: .leading, spacing: coordinator.compactEditor ? 8 : 10) {
            HStack(spacing: 8) {
                // Selection identity lives here. Discovery markers are already
                // gone while this panel is visible, leaving the actual themed
                // UI completely unobstructed during color evaluation.
                Image(systemName: "paintbrush.pointed.fill")
                    .foregroundStyle(.yellow)
                Text(isExactElement ? "This Element · \(role.displayName)" : role.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 5)
                Button {
                    coordinator.dockEditorAtTop.toggle()
                } label: {
                    Image(systemName: coordinator.dockEditorAtTop ? "arrow.down.to.line.compact" : "arrow.up.to.line.compact")
                }
                .accessibilityLabel(coordinator.dockEditorAtTop ? "Move editor to bottom" : "Move editor to top")
                Button {
                    coordinator.compactEditor.toggle()
                } label: {
                    Image(systemName: coordinator.compactEditor ? "chevron.up" : "chevron.down")
                }
                .accessibilityLabel(coordinator.compactEditor ? "Expand color controls" : "Collapse color controls")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)

            if !coordinator.compactEditor {
                Text(isExactElement
                     ? "This is a local exception. Other elements using \(role.displayName) keep following the theme role."
                     : role.usageDescription)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.74))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    ColorPicker("Color", selection: colorBinding(for: role), supportsOpacity: true)
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hexValue(current))
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        Text(current.alpha < 0.999 ? "Opacity: \(Int((current.alpha * 100).rounded()))%" : "Fully opaque")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                    Button("Original") {
                        if let originalColor = coordinator.originalColor {
                            themes.updateColorPreview(originalColor, for: role, in: themes.selectedThemeID)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(coordinator.originalColor == nil || current == coordinator.originalColor)
                }

                slider("Hue", component: .hue, role: role)
                slider("Saturation", component: .saturation, role: role)
                slider("Brightness", component: .brightness, role: role)
                slider("Opacity", component: .alpha, role: role)
            }

            if let elementID = coordinator.editingElementID,
               themes.hasElementOverride(elementID, in: themes.selectedThemeID) {
                Button("Use Theme Color Instead") {
                    coordinator.removeCurrentElementOverride()
                }
                .font(.caption.weight(.semibold))
            }

            HStack(spacing: 9) {
                Button("Cancel") { coordinator.finishRole(save: false) }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
                Button(isExactElement ? "Save Element" : "Save Color") { coordinator.finishRole(save: true) }
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

    private func pickTarget(at point: CGPoint) {
        let request = UUID()
        inspectionRequest = request
        guard let root = currentPresentationRoot(in: baseWindow) else { return }
        presentationID = ObjectIdentifier(root)
        let targets = normalizedTargets(
            registry.visibleTargets(in: baseWindow, within: root) +
                ThemeUIKitTargetDiscovery.targets(in: root, window: baseWindow),
            visibleIn: baseWindow.bounds
        )
        let reportWebViews = ThemeReportBridge.shared.visibleWebViews(in: baseWindow, within: root)
        // Reports are real WKWebViews rather than SwiftUI target rectangles.
        // Ask the DOM which semantic CSS variables style the exact element.
        if let webView = reportWebViews.reversed().first(where: {
            ThemeReportBridge.shared.frame(of: $0, in: baseWindow).contains(point)
        }) {
            ThemeReportBridge.shared.roles(at: point, in: webView, window: baseWindow) { roles in
                guard coordinator.isPicking, inspectionRequest == request,
                      currentPresentationRoot(in: baseWindow) === root,
                      webView.window === baseWindow else { return }
                coordinator.presentRoles(roles)
            }
            return
        }

        let hits = NBThemeInspectorRegistry.pickTargets(targets, at: point)

        var candidates: [ThemeEditingCandidate] = []
        var seenElements = Set<String>()
        var seenRoles = Set<NBThemeRole>()
        for hit in hits {
            if let elementID = hit.elementID,
               seenElements.insert("\(hit.role.rawValue)|\(elementID)").inserted {
                candidates.append(.init(role: hit.role, elementID: elementID, initialColor: hit.initialColor))
            }
            if seenRoles.insert(hit.role).inserted {
                candidates.append(.init(role: hit.role, elementID: nil))
            }
        }

        // Pixels cannot establish semantic ownership: artwork and fixed colors
        // can equal any theme role, including black/white and translucent mixes.
        // With no registered target, show a miss rather than edit an unrelated role.
        coordinator.presentTargets(candidates)
    }

    private func colorBinding(for role: NBThemeRole) -> Binding<Color> {
        Binding(
            get: { currentEditingColor(for: role).color },
            set: {
                themes.updateColorPreview(
                    NBThemeColor(uiColor: UIColor($0)),
                    for: role,
                    in: themes.selectedThemeID
                )
            }
        )
    }

    private enum ColorComponent { case hue, saturation, brightness, alpha }

    private func slider(_ title: String, component: ColorComponent, role: NBThemeRole) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption)
                .frame(width: 74, alignment: .leading)
            Slider(value: componentBinding(component, role: role), in: 0...1)
                .accessibilityLabel(title)
            Text("\(Int((componentBinding(component, role: role).wrappedValue * 100).rounded()))")
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 29, alignment: .trailing)
        }
    }

    private func componentBinding(_ component: ColorComponent, role: NBThemeRole) -> Binding<Double> {
        Binding(
            get: {
                let rgba = currentEditingColor(for: role)
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
                let rgba = currentEditingColor(for: role)
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
                themes.updateColorPreview(
                    NBThemeColor(uiColor: UIColor(
                        hue: hue,
                        saturation: saturation,
                        brightness: brightness,
                        alpha: alpha
                    )),
                    for: role,
                    in: themes.selectedThemeID
                )
            }
        )
    }

    private func currentEditingColor(for role: NBThemeRole) -> NBThemeColor {
        if let elementID = coordinator.editingElementID {
            return themes.activeColor(for: role, elementID: elementID)
        }
        return themes.activeColor(for: role)
    }

    private func hexValue(_ color: NBThemeColor) -> String {
        String(
            format: "#%02X%02X%02X",
            Int((color.red * 255).rounded()),
            Int((color.green * 255).rounded()),
            Int((color.blue * 255).rounded())
        )
    }
}

// MARK: - Overlay hit regions

private struct ThemeOverlayHitRegionPreferenceKey: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    func themeOverlayHitRegion() -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ThemeOverlayHitRegionPreferenceKey.self,
                    value: [geometry.frame(in: .global)]
                )
            }
        }
    }
}

// MARK: - Presentation discovery

private func currentPresentationRoot(in window: UIWindow) -> UIView? {
    guard let root = window.rootViewController else { return window }
    return topmostPresentedController(from: root).view
}

private func topmostPresentedController(from root: UIViewController) -> UIViewController {
    var current = root
    while let presented = firstPresentedController(in: current) {
        current = presented
    }
    return current
}

private func firstPresentedController(in controller: UIViewController) -> UIViewController? {
    if let presented = controller.presentedViewController {
        return presented
    }

    if let navigation = controller as? UINavigationController {
        return navigation.visibleViewController.flatMap { firstPresentedController(in: $0) }
    }

    if let tab = controller as? UITabBarController {
        return tab.selectedViewController.flatMap { firstPresentedController(in: $0) }
    }

    for child in controller.children.reversed()
    where child.isViewLoaded && child.view.window != nil && !child.view.isHidden {
        if let presented = firstPresentedController(in: child) {
            return presented
        }
    }
    return nil
}

// MARK: - Native UIKit target discovery

@MainActor
private enum ThemeUIKitTargetDiscovery {
    static func targets(in root: UIView, window: UIWindow) -> [NBThemeInspectorTargetFrame] {
        var stack = [root]
        var targets: [NBThemeInspectorTargetFrame] = []

        while let view = stack.popLast() {
            guard !view.isHidden, view.alpha > 0.02, view.window === window else { continue }
            stack.append(contentsOf: view.subviews)

            let rect = NBThemeInspectorRegistry.visibleFrame(of: view, in: window)
            guard !rect.isNull, rect.width > 1, rect.height > 1, rect.intersects(window.bounds) else { continue }

            if let table = view as? UITableView, table.delegate is SourceAppsTableRepresentableView.Coordinator {
                for cell in table.visibleCells {
                    let cellRect = NBThemeInspectorRegistry.visibleFrame(of: cell, in: window)
                    add(.separator, CGRect(x: cellRect.minX, y: cellRect.maxY - 1, width: cellRect.width, height: 1), to: &targets)
                }
                if table.dataSource?.sectionIndexTitles?(for: table)?.isEmpty == false {
                    add(.accent, CGRect(x: rect.maxX - 20, y: rect.minY, width: 20, height: rect.height), to: &targets)
                }
            }

            if view is UINavigationBar {
                add(.navigationBackground, rect, to: &targets)
                add(.navigationShadow, CGRect(x: rect.minX, y: rect.maxY - 4, width: rect.width, height: 4), to: &targets)
            }

            if let label = view as? UILabel,
               let nav = ancestor(UINavigationBar.self, from: view),
               let actualTitle = nav.topItem?.title,
               label.text == actualTitle {
                add(label.font.pointSize >= 22 ? .navigationTitle : .navigationText, rect, to: &targets)
            }

            if view is UIButton, ancestor(UINavigationBar.self, from: view) != nil {
                add(.barButtonTint, rect, to: &targets)
                let identifier = [view.accessibilityLabel, view.accessibilityIdentifier]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .lowercased()
                if identifier.contains("back") || identifier.contains("return") {
                    add(.navigationTint, rect, to: &targets)
                }
            }

            if let tab = view as? UITabBar {
                add(.tabBackground, rect, to: &targets)
                add(.tabShadow, CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 4), to: &targets)
                let items = tab.subviews.compactMap { $0 as? UIControl }
                    .filter { !$0.isHidden && $0.bounds.width > 10 }
                for item in items {
                    let itemRect = NBThemeInspectorRegistry.visibleFrame(of: item, in: window)
                    add(item.isSelected ? .tabSelected : .tabUnselected, itemRect, to: &targets)
                }
            }

            if view is UISearchTextField {
                add(.searchBackground, rect, to: &targets)
                add(.searchText, rect, to: &targets)
                add(.searchPlaceholder, rect, to: &targets)
                add(.searchTint, rect, to: &targets)
            }

            if let segment = view as? UISegmentedControl, segment.numberOfSegments > 0 {
                add(.segmentBackground, rect, to: &targets)
                let width = rect.width / CGFloat(segment.numberOfSegments)
                for index in 0..<segment.numberOfSegments {
                    let segmentRect = CGRect(
                        x: rect.minX + width * CGFloat(index),
                        y: rect.minY,
                        width: width,
                        height: rect.height
                    )
                    if index == segment.selectedSegmentIndex {
                        add(.segmentSelectedBackground, segmentRect, to: &targets)
                        add(.segmentSelectedText, segmentRect, to: &targets)
                    } else {
                        add(.segmentText, segmentRect, to: &targets)
                    }
                }
            }
        }

        return targets
    }

    private static func add(
        _ role: NBThemeRole,
        _ frame: CGRect,
        to targets: inout [NBThemeInspectorTargetFrame]
    ) {
        guard !frame.isNull, !frame.isEmpty,
              frame.minX.isFinite, frame.minY.isFinite,
              frame.width.isFinite, frame.height.isFinite else { return }
        let isChrome = role == .navigationBackground || role == .tabBackground
        targets.append(.init(role: role, frame: frame,
                             kind: isChrome ? .chrome : .control,
                             alpha: NBThemeManager.shared.activeColor(for: role).alpha))
    }

    private static func ancestor<T: UIView>(_ type: T.Type, from view: UIView) -> T? {
        var parent = view.superview
        while let current = parent {
            if let matched = current as? T { return matched }
            parent = current.superview
        }
        return nil
    }
}

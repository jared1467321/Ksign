import SwiftUI
import UIKit

/// The system still owns the title, search field, back button and toolbar
/// actions. Only their backing changes to a single clear glass card.
struct NBThemeNavigationBridge: UIViewRepresentable {
    @ObservedObject private var themes = NBThemeManager.shared
    @AppStorage("Feather.auroraBackground") private var aurora = true
    @AppStorage("Feather.glossySurfaces") private var glass = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func makeUIView(context: Context) -> NavigationBackdropProbe {
        NavigationBackdropProbe(frame: .zero)
    }

    func updateUIView(_ view: NavigationBackdropProbe, context: Context) {
        view.clearContainers = aurora && !reduceTransparency && contrast != .increased
        view.showGlass = view.clearContainers && glass
        view.scheduleUpdate()
    }
}

final class NavigationBackdropProbe: UIView {
    var clearContainers = false
    var showGlass = false
    private var updatePending = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleUpdate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleUpdate()
    }

    func scheduleUpdate() {
        guard !updatePending else { return }
        updatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updatePending = false
            self.updateNavigation()
        }
    }

    private func updateNavigation() {
        guard window != nil else { return }
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                if clearContainers {
                    // SwiftUI's scroll background modifier does not clear the
                    // UIKit hosting/navigation containers behind the bar.
                    controller.view.backgroundColor = .clear
                }
                if let navigation = controller as? UINavigationController ?? controller.navigationController {
                    if clearContainers {
                        navigation.view.backgroundColor = .clear
                        navigation.tabBarController?.view.backgroundColor = .clear
                    }
                    updateBar(navigation.navigationBar)
                    return
                }
            }
            responder = current.next
        }
    }

    private func updateBar(_ bar: UINavigationBar) {
        let panel: NavigationGlassPanelView
        if let existing = bar.subviews.first(where: { $0 is NavigationGlassPanelView }) as? NavigationGlassPanelView {
            panel = existing
        } else {
            guard showGlass else { return }
            panel = NavigationGlassPanelView(frame: .zero)
            panel.frame = bar.bounds
            panel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            bar.insertSubview(panel, at: 0)
        }
        panel.isHidden = !showGlass
        if panel.frame != bar.bounds { panel.frame = bar.bounds }
        // Keep the panel behind UIKit's controls as the large title collapses
        // or a search field moves into/out of the navigation bar.
        bar.sendSubviewToBack(panel)
    }
}

private final class NavigationGlassPanelView: UIView {
    private let host = UIHostingController(rootView: NavigationGlassPanel())

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        addSubview(host.view)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        host.view.frame = bounds.insetBy(dx: 12, dy: 4)
    }
}

private struct NavigationGlassPanel: View {
    @ObservedObject private var themes = NBThemeManager.shared

    var body: some View {
        NBThemeSurface(themes.activeColor(for: .navigationBackground),
                       in: RoundedRectangle(cornerRadius: 28, style: .continuous),
                       tintStrength: 0.025)
            .environment(\.colorScheme, themes.isDark ? .dark : .light)
            .ignoresSafeArea()
    }
}

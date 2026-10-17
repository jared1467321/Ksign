import SwiftUI
import UIKit

/// The large pane is a sibling BELOW the native navigation bar. Keeping it
/// outside the bar's render group leaves the title and glass buttons above it.
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
        view.showGlass = aurora && glass && !reduceTransparency && contrast != .increased
        view.scheduleUpdate()
    }
}

final class NavigationBackdropProbe: UIView {
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
            if let controller = current as? UIViewController,
               let navigation = controller as? UINavigationController ?? controller.navigationController {
                updateBar(navigation.navigationBar)
                return
            }
            responder = current.next
        }
    }

    private func updateBar(_ bar: UINavigationBar) {
        guard let container = bar.superview else { return }
        let panel: NavigationGlassPanelView
        if let existing = container.subviews.compactMap({ $0 as? NavigationGlassPanelView })
            .first(where: { $0.navigationBar === bar }) {
            panel = existing
        } else {
            guard showGlass else { return }
            panel = NavigationGlassPanelView(frame: .zero)
            panel.navigationBar = bar
            panel.translatesAutoresizingMaskIntoConstraints = false
            container.insertSubview(panel, belowSubview: bar)
            NSLayoutConstraint.activate([
                panel.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                panel.topAnchor.constraint(equalTo: bar.topAnchor),
                panel.bottomAnchor.constraint(equalTo: bar.bottomAnchor)
            ])
        }
        panel.isHidden = !showGlass
    }
}

private final class NavigationGlassPanelView: UIView {
    weak var navigationBar: UINavigationBar?
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
                       tintStrength: 0.025, finish: .navigation)
            .environment(\.colorScheme, themes.isDark ? .dark : .light)
            .ignoresSafeArea()
    }
}

import SwiftUI
import UIKit

/// The title capsule is a sibling BELOW the native navigation bar. Keeping it
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
        let title = bar.topItem?.title ?? ""
        let font = bar.titleTextAttributes?[.font] as? UIFont ?? UIFont.preferredFont(forTextStyle: .headline)
        let titleSize = (title as NSString).size(withAttributes: [.font: font])
        // Leave toolbar buttons on their own native glass. The title's pane
        // stays inside the inline bar, clear of both the status bar and rows.
        let width = min(ceil(titleSize.width) + 32, max(0, bar.bounds.width - 120))
        let height = min(ceil(titleSize.height) + 12, max(0, bar.bounds.height - 4))
        let horizontalInset = (bar.bounds.width - width) / 2
        let verticalInset = (bar.bounds.height - height) / 2
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
            panel.barConstraints = [
                panel.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                panel.topAnchor.constraint(equalTo: bar.topAnchor),
                panel.bottomAnchor.constraint(equalTo: bar.bottomAnchor)
            ]
            NSLayoutConstraint.activate(panel.barConstraints)
        }
        for (constraint, inset) in zip(panel.barConstraints,
                                       [horizontalInset, -horizontalInset, verticalInset, -verticalInset]) {
            constraint.constant = inset
        }
        // Large titles retain their native layout; a centered capsule belongs
        // only to inline titles, including Settings and its child screens.
        panel.isHidden = !showGlass || title.isEmpty || width <= 0 || height <= 0 || bar.bounds.height > 64
    }
}

private final class NavigationGlassPanelView: UIView {
    weak var navigationBar: UINavigationBar?
    var barConstraints: [NSLayoutConstraint] = []
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
        host.view.frame = bounds
    }
}

private struct NavigationGlassPanel: View {
    @ObservedObject private var themes = NBThemeManager.shared

    var body: some View {
        NBThemeSurface(themes.activeColor(for: .navigationBackground),
                       in: Capsule(),
                       tintStrength: 0.025, finish: .navigation)
            .environment(\.colorScheme, themes.isDark ? .dark : .light)
            .ignoresSafeArea()
    }
}

import SwiftUI

private struct NBNavigationAccessoryKey: EnvironmentKey {
    static var defaultValue: AnyView? { nil }
}

public extension View {
    /// Supplies an optional app-wide control to themed navigation bars.
    func nbNavigationAccessory<Accessory: View>(_ accessory: Accessory?) -> some View {
        environment(\.nbNavigationAccessory, accessory.map { AnyView($0) })
    }

    func nbNavigationAccessoryToolbar(placement: ToolbarItemPlacement = .topBarTrailing) -> some View {
        modifier(NBNavigationAccessoryModifier(placement: placement))
    }

    /// Keep the title and its glass in one layout so padding stays symmetric
    /// even when UIKit changes the toolbar's vertical alignment.
    func nbThemeNavigationTitle(
        _ title: String,
        displayMode: NavigationBarItem.TitleDisplayMode = .inline
    ) -> some View {
        modifier(NBThemeNavigationTitleModifier(title: title, displayMode: displayMode))
    }
}

private extension EnvironmentValues {
    var nbNavigationAccessory: AnyView? {
        get { self[NBNavigationAccessoryKey.self] }
        set { self[NBNavigationAccessoryKey.self] = newValue }
    }
}

private struct NBNavigationAccessoryModifier: ViewModifier {
    @Environment(\.nbNavigationAccessory) private var accessory
    let placement: ToolbarItemPlacement

    func body(content: Content) -> some View {
        content.toolbar {
            if let accessory {
                ToolbarItem(placement: placement) {
                    accessory
                }
            }
        }
    }
}

private struct NBThemeNavigationTitleModifier: ViewModifier {
    @ObservedObject private var themes = NBThemeManager.shared
    @AppStorage("Feather.auroraBackground") private var aurora = true
    @AppStorage("Feather.glossySurfaces") private var glass = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let title: String
    let displayMode: NavigationBarItem.TitleDisplayMode

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(displayMode)
            .toolbar {
                if displayMode == .inline && !title.isEmpty && aurora && glass
                    && !reduceTransparency && contrast != .increased {
                    ToolbarItem(placement: .principal) {
                        Text(title)
                            .font(.headline)
                            .nbThemeForeground(.navigationText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background {
                                NBThemeSurface(themes.activeColor(for: .navigationBackground),
                                               in: Capsule(), tintStrength: 0.025, finish: .navigation)
                            }
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
            .nbNavigationAccessoryToolbar(placement: displayMode == .inline ? .topBarTrailing : .principal)
    }
}

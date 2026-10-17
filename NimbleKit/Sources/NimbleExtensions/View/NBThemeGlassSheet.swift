import SwiftUI

private struct NBThemeGlassSheetKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Only explicitly presented glass drawers inherit their backing. Normal
    /// screens still draw a sky inside their own navigation hosting controller.
    var nbThemeUsesGlassSheet: Bool {
        get { self[NBThemeGlassSheetKey.self] }
        set { self[NBThemeGlassSheetKey.self] = newValue }
    }
}

public extension View {
    /// A transparent drawer over the presenting screen, without another sky.
    func nbThemeGlassSheet() -> some View {
        modifier(NBThemeGlassSheetModifier())
    }
}

private struct NBThemeGlassSheetModifier: ViewModifier {
    @ObservedObject private var themes = NBThemeManager.shared

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.4, tvOS 16.4, *) {
            content
                .environment(\.nbThemeUsesGlassSheet, true)
                .presentationBackground {
                    NBThemeSurface(themes.activeColor(for: .background),
                                   in: Rectangle(), tintStrength: 0.005, finish: .sheet)
                }
        } else {
            // Older sheets cannot replace their system presentation backing.
            content
        }
    }
}

struct NBThemeSheetNavigationBackgroundModifier: ViewModifier {
    let clear: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, tvOS 18.0, *), clear {
            content.containerBackground(.clear, for: .navigation)
        } else {
            content
        }
    }
}

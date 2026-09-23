// Live theme inspector hooks. These have no visual or layout effect outside
// the editor; the marker is attached to the actual view that consumes a role.

import SwiftUI
import NimbleExtensions

private struct NBInspectedThemeRoleKey: EnvironmentKey {
    static let defaultValue: NBThemeRole? = nil
}

public extension EnvironmentValues {
    var nbInspectedThemeRole: NBThemeRole? {
        get { self[NBInspectedThemeRoleKey.self] }
        set { self[NBInspectedThemeRoleKey.self] = newValue }
    }
}

public extension View {
    /// Show a focus ring around this real element when its color is inspected.
    func nbThemeInspectorTarget(_ role: NBThemeRole) -> some View {
        modifier(NBThemeInspectorTargetModifier(role: role))
    }
}

private struct NBThemeInspectorTargetModifier: ViewModifier {
    @Environment(\.nbInspectedThemeRole) private var inspectedRole
    let role: NBThemeRole

    func body(content: Content) -> some View {
        content.overlay {
            if inspectedRole == role {
                NBThemeFocusRing()
                    .padding(-3)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct NBThemeFocusRing: View {
    @State private var dimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(.yellow.opacity(dimmed ? 0.52 : 1), lineWidth: 3)
            .shadow(color: .black.opacity(0.8), radius: 2)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

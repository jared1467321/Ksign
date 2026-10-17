import Foundation

// Platform doubles are limited to storage annotations and the unused SwiftUI
// color bridge. The theme model, migration and editing logic run verbatim.
public protocol ObservableObject {}
@propertyWrapper public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    public init(initialValue: Value) { self.wrappedValue = initialValue }
}
public enum ColorScheme { case light, dark }
public struct Color {
    public enum RGBColorSpace { case sRGB }
    public init(_ space: RGBColorSpace, red: Double, green: Double, blue: Double, opacity: Double) {}
}

@main
enum ThemeTests {
    static func main() throws {
        try palettesAndCompatibility()
        try editingAndPersistence()
        try upgradeAndRestore()
        print("Theme tests passed: palette contrast, legacy profiles, adaptive edits, previews, persistence, upgrade and restore.")
    }

    static func store() -> UserDefaults {
        UserDefaults(suiteName: "asign-theme-test-\(UUID().uuidString)")!
    }

    static func luminance(_ color: NBThemeColor) -> Double {
        func linear(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return linear(color.red) * 0.2126 + linear(color.green) * 0.7152 + linear(color.blue) * 0.0722
    }

    static func contrast(_ foreground: NBThemeColor, _ background: NBThemeColor) -> Double {
        let a = luminance(foreground), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func palettesAndCompatibility() throws {
        for dark in [true, false] {
            let palette = NBThemeProfile.liquidGlass.resolved(isDark: dark)
            assert(Set(palette.colors.keys) == Set(NBThemeRole.allCases.map(\.rawValue)))
            for (text, surface) in [(NBThemeRole.text, NBThemeRole.background), (.textSecondary, .elevated),
                                    (.reportText, .reportCard), (.reportDim, .reportBackground),
                                    (.onAccent, .accent), (.segmentSelectedText, .segmentSelectedBackground),
                                    (.liveActivityPrimaryText, .liveActivityBackground)] {
                assert(contrast(palette.color(for: text), palette.color(for: surface)) >= 4.5,
                       "Low contrast for \(text) on \(surface), dark=\(dark)")
            }
        }
        let legacy = Data(#"{"id":"old","name":"Original","colors":{"text":{"red":0.3,"green":0.4,"blue":0.5,"alpha":1}}}"#.utf8)
        let decoded = try JSONDecoder().decode(NBThemeProfile.self, from: legacy)
        assert(decoded.lightColors == nil && decoded.elementOverrides.isEmpty)
        assert(decoded.resolved(isDark: false).colors == decoded.colors)
        let roundTrip = try JSONDecoder().decode(NBThemeProfile.self, from: JSONEncoder().encode(decoded))
        assert(roundTrip == decoded)
    }

    static func editingAndPersistence() throws {
        let defaults = store()
        let themes = NBThemeManager(defaults: defaults)
        themes.setColorScheme(.light)
        let copy = themes.duplicateActiveTheme()
        assert(copy.colors == NBThemeProfile.liquidGlass.colors, "Duplicating in Light must retain Dark")
        assert(copy.lightColors == NBThemeProfile.liquidGlass.lightColors)
        let originalDark = themes.customThemes[0].colors
        let edited = NBThemeColor(red: 0.2, green: 0.3, blue: 0.4)
        themes.setColor(edited, for: .text)
        assert(themes.activeColor(for: .text) == edited)
        assert(themes.customThemes[0].colors == originalDark)

        let beforePreview = defaults.data(forKey: "Ksign.themeProfiles.v1")
        themes.beginColorPreview(for: .accent, elementID: "button", in: copy.id)
        themes.updateColorPreview(edited, for: .accent, in: copy.id)
        assert(themes.activeColor(for: .accent, elementID: "button") == edited)
        assert(themes.activeColor(for: .accent) != edited)
        assert(defaults.data(forKey: "Ksign.themeProfiles.v1") == beforePreview)
        themes.endColorPreview(for: .accent, in: copy.id, save: true)
        assert(themes.hasElementOverride("button"))
        themes.setColorScheme(.dark)
        assert(!themes.hasElementOverride("button"), "Light element edits must not leak into Dark")
        assert(themes.activeColor(for: .text) == NBThemeProfile.liquidGlass.color(for: .text))
        themes.setColorScheme(.light)
        assert(themes.activeColor(for: .accent, elementID: "button") == edited)

        themes.beginColorPreview(for: .text, in: copy.id)
        themes.updateColorPreview(NBThemeColor(red: 1, green: 0, blue: 0), for: .text, in: copy.id)
        themes.setColorScheme(.dark)
        assert(!themes.isColorPreviewActive, "Appearance changes must discard in-progress edits")
        themes.setColorScheme(.light)
        assert(themes.activeColor(for: .text) == edited)

        let reopened = NBThemeManager(defaults: defaults)
        reopened.setColorScheme(.light)
        assert(reopened.activeColor(for: .text) == edited)
        assert(reopened.activeColor(for: .accent, elementID: "button") == edited)
        reopened.clearElementOverride("button")
        assert(!reopened.hasElementOverride("button"))
        reopened.resetActiveThemeColors()
        assert(reopened.activeTheme.colors == NBThemeProfile.halloween.lightColors)
        reopened.setColorScheme(.dark)
        assert(reopened.activeTheme.colors == NBThemeProfile.halloween.colors)
    }

    static func upgradeAndRestore() throws {
        let defaults = store()
        defaults.set(NBThemeProfile.halloweenID, forKey: "Ksign.selectedThemeProfile.v1")
        let themes = NBThemeManager(defaults: defaults)
        assert(themes.selectedThemeID == NBThemeProfile.liquidGlassID)
        themes.selectTheme(id: NBThemeProfile.halloweenID)
        assert(NBThemeManager(defaults: defaults).selectedThemeID == NBThemeProfile.halloweenID,
               "An explicit Halloween choice must survive relaunch")
        themes.selectTheme(id: NBThemeProfile.liquidGlassID)
        themes.beginColorPreview(for: .text, in: NBThemeProfile.liquidGlassID)
        assert(!themes.isColorPreviewActive, "Built-in palettes are immutable")

        let old = NBThemeProfile(id: "old", name: "Saved", colors: NBThemeProfile.halloween.colors)
        let customDefaults = store()
        customDefaults.set(try JSONEncoder().encode([old]), forKey: "Ksign.themeProfiles.v1")
        customDefaults.set(old.id, forKey: "Ksign.selectedThemeProfile.v1")
        let custom = NBThemeManager(defaults: customDefaults)
        assert(custom.selectedThemeID == old.id)
        custom.setColorScheme(.light)
        assert(custom.activeTheme.colors == old.colors)

        // Restore happens while the process is alive and must not rerun the
        // one-time default migration or require a launch to resolve colors.
        defaults.set(try JSONEncoder().encode([old]), forKey: "Ksign.themeProfiles.v1")
        defaults.set(old.id, forKey: "Ksign.selectedThemeProfile.v1")
        themes.reloadFromDefaults()
        assert(themes.selectedThemeID == old.id && themes.customThemes == [old])
    }
}

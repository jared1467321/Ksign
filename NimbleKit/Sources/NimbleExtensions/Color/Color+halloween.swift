//
//  Color+halloween.swift
//  NimbleKit
//
//  Theme storage and the compatibility facade used by Ksign/NimbleViews.
//
//  The original Halloween palette remains the built-in default, but colors are
//  now resolved from the selected theme profile at runtime. Keeping the
//  NBHalloween name avoids forcing every existing call site to know about the
//  profile store while still making those call sites fully theme-aware.
//

import Combine
import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Serializable color

public struct NBThemeColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
        self.alpha = min(1, max(0, alpha))
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    public func interpolated(to other: NBThemeColor, fraction: Double) -> NBThemeColor {
        let t = min(1, max(0, fraction))
        return NBThemeColor(
            red: red + ((other.red - red) * t),
            green: green + ((other.green - green) * t),
            blue: blue + ((other.blue - blue) * t),
            alpha: alpha + ((other.alpha - alpha) * t)
        )
    }

    public var cssRGBA: String {
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        let alphaString = String(format: "%.4f", alpha)
        return "rgba(\(r),\(g),\(b),\(alphaString))"
    }

#if canImport(UIKit)
    public var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    public init(uiColor: UIColor) {
        let resolved = uiColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        if resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            self.init(
                red: Double(red),
                green: Double(green),
                blue: Double(blue),
                alpha: Double(alpha)
            )
            return
        }

        var white: CGFloat = 0
        if resolved.getWhite(&white, alpha: &alpha) {
            self.init(
                red: Double(white),
                green: Double(white),
                blue: Double(white),
                alpha: Double(alpha)
            )
            return
        }

        preconditionFailure("Unable to convert UIColor into an sRGB theme color")
    }
#endif
}

// MARK: - Theme roles

public enum NBThemeRole: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    // Core surfaces and text.
    case background
    case elevated
    case elevatedHigh
    case controlFill
    case controlFillStrong
    case overlaySurface
    case overlayScrim
    case imageScrim
    case mask
    case shadow
    case text
    case textSecondary
    case textTertiary
    case disabledText
    case onAccent
    case overlayText

    // General chrome and status.
    case accent
    case secondaryAccent
    case tertiaryAccent
    case title
    case selection
    case heading
    case headingFill
    case separator
    case border
    case imageBorder
    case success
    case warning
    case danger
    case expired

    // UIKit-backed chrome.
    case navigationBackground
    case navigationTitle
    case navigationText
    case navigationTint
    case navigationShadow
    case tabBackground
    case tabSelected
    case tabUnselected
    case tabShadow
    case searchBackground
    case searchText
    case searchPlaceholder
    case searchTint
    case segmentBackground
    case segmentSelectedBackground
    case segmentText
    case segmentSelectedText
    case barButtonTint

    // Live Activity / Dynamic Island.
    case liveActivityBackground
    case liveActivityActionText
    case liveActivityPrimaryText
    case liveActivitySecondaryText
    case liveActivityRunning
    case liveActivityIdle

    // Crypt Check HTML reports.
    case reportBackground
    case reportCard
    case reportBorder
    case reportText
    case reportDim
    case reportAccent
    case reportSuccess
    case reportWarning
    case reportDanger
    case reportSuccessFill
    case reportWarningFill
    case reportDangerFill
    case reportTapHighlight
    case reportPink
    case reportPurple
    case reportBlue
    case reportLime
    case reportInteractiveFill
    case reportInteractiveBorder
    case reportSelectedFill
    case reportSelectedText
    case reportDropdown
    case reportShadow

    public var id: String { rawValue }

    public enum Category: String, CaseIterable, Identifiable, Sendable {
        case surfaces = "Surfaces"
        case text = "Text"
        case accents = "Accents & Status"
        case navigation = "Navigation & Controls"
        case liveActivity = "Live Activity"
        case reports = "Crypt Check Reports"

        public var id: String { rawValue }
    }

    public var category: Category {
        switch self {
        case .background, .elevated, .elevatedHigh, .controlFill, .controlFillStrong,
             .overlaySurface, .overlayScrim, .imageScrim, .mask, .shadow:
            return .surfaces
        case .text, .textSecondary, .textTertiary, .disabledText, .onAccent, .overlayText:
            return .text
        case .accent, .secondaryAccent, .tertiaryAccent, .title, .selection,
             .heading, .headingFill, .separator, .border, .imageBorder,
             .success, .warning, .danger, .expired:
            return .accents
        case .navigationBackground, .navigationTitle, .navigationText, .navigationTint,
             .navigationShadow, .tabBackground, .tabSelected, .tabUnselected,
             .tabShadow, .searchBackground, .searchText, .searchPlaceholder,
             .searchTint, .segmentBackground, .segmentSelectedBackground,
             .segmentText, .segmentSelectedText, .barButtonTint:
            return .navigation
        case .liveActivityBackground, .liveActivityActionText, .liveActivityPrimaryText,
             .liveActivitySecondaryText, .liveActivityRunning, .liveActivityIdle:
            return .liveActivity
        case .reportBackground, .reportCard, .reportBorder, .reportText, .reportDim,
             .reportAccent, .reportSuccess, .reportWarning, .reportDanger,
             .reportSuccessFill, .reportWarningFill, .reportDangerFill, .reportTapHighlight, .reportPink,
             .reportPurple, .reportBlue, .reportLime, .reportInteractiveFill,
             .reportInteractiveBorder, .reportSelectedFill, .reportSelectedText,
             .reportDropdown, .reportShadow:
            return .reports
        }
    }

    public var displayName: String {
        switch self {
        case .background: return "Page Background"
        case .elevated: return "Rows & Cards"
        case .elevatedHigh: return "Raised Surface"
        case .controlFill: return "Control Fill"
        case .controlFillStrong: return "Strong Control Fill"
        case .overlaySurface: return "Overlay Surface"
        case .overlayScrim: return "Overlay Scrim"
        case .imageScrim: return "Image Scrim"
        case .mask: return "Mask"
        case .shadow: return "Shadow"
        case .text: return "Primary Text"
        case .textSecondary: return "Secondary Text"
        case .textTertiary: return "Tertiary Text"
        case .disabledText: return "Disabled Text"
        case .onAccent: return "Text on Accent"
        case .overlayText: return "Overlay Text"
        case .accent: return "Primary Accent"
        case .secondaryAccent: return "Secondary Accent"
        case .tertiaryAccent: return "Tertiary Accent"
        case .title: return "Large Titles"
        case .selection: return "Selection"
        case .heading: return "Section Headings"
        case .headingFill: return "Heading Badge Fill"
        case .separator: return "Separators"
        case .border: return "Borders"
        case .imageBorder: return "Image Borders"
        case .success: return "Success"
        case .warning: return "Warning / In Progress"
        case .danger: return "Danger / Destructive"
        case .expired: return "Expired / Inactive"
        case .navigationBackground: return "Navigation Background"
        case .navigationTitle: return "Navigation Large Title"
        case .navigationText: return "Navigation Title Text"
        case .navigationTint: return "Navigation Tint"
        case .navigationShadow: return "Navigation Shadow"
        case .tabBackground: return "Tab Bar Background"
        case .tabSelected: return "Selected Tab"
        case .tabUnselected: return "Unselected Tab"
        case .tabShadow: return "Tab Bar Shadow"
        case .searchBackground: return "Search Background"
        case .searchText: return "Search Text"
        case .searchPlaceholder: return "Search Placeholder"
        case .searchTint: return "Search Tint"
        case .segmentBackground: return "Segment Background"
        case .segmentSelectedBackground: return "Selected Segment Fill"
        case .segmentText: return "Segment Text"
        case .segmentSelectedText: return "Selected Segment Text"
        case .barButtonTint: return "Bar Button Tint"
        case .liveActivityBackground: return "Activity Background"
        case .liveActivityActionText: return "System Action Text"
        case .liveActivityPrimaryText: return "Activity Primary Text"
        case .liveActivitySecondaryText: return "Activity Secondary Text"
        case .liveActivityRunning: return "Activity Running"
        case .liveActivityIdle: return "Activity Idle"
        case .reportBackground: return "Report Background"
        case .reportCard: return "Report Cards"
        case .reportBorder: return "Report Borders"
        case .reportText: return "Report Text"
        case .reportDim: return "Report Secondary Text"
        case .reportAccent: return "Report Accent"
        case .reportSuccess: return "Report Success"
        case .reportWarning: return "Report Warning"
        case .reportDanger: return "Report Danger"
        case .reportSuccessFill: return "Report Success Fill"
        case .reportWarningFill: return "Report Warning Fill"
        case .reportDangerFill: return "Report Danger Fill"
        case .reportTapHighlight: return "Report Tap Highlight"
        case .reportPink: return "Report Pink"
        case .reportPurple: return "Report Purple"
        case .reportBlue: return "Report Blue"
        case .reportLime: return "Report Lime"
        case .reportInteractiveFill: return "Report Control Fill"
        case .reportInteractiveBorder: return "Report Control Border"
        case .reportSelectedFill: return "Report Selected Fill"
        case .reportSelectedText: return "Report Selected Text"
        case .reportDropdown: return "Report Dropdown"
        case .reportShadow: return "Report Shadow"
        }
    }
}

// MARK: - Theme profile

public struct NBThemeProfile: Codable, Hashable, Identifiable, Sendable {
    public static let halloweenID = "builtin.halloween"

    public var id: String
    public var name: String
    public var colors: [String: NBThemeColor]

    public init(id: String = UUID().uuidString, name: String, colors: [String: NBThemeColor]) {
        self.id = id
        self.name = name
        self.colors = colors
    }

    public var isBuiltIn: Bool { id == Self.halloweenID }

    public func color(for role: NBThemeRole) -> NBThemeColor {
        if let color = colors[role.rawValue] { return color }
        guard let fallback = Self.halloween.colors[role.rawValue] else {
            preconditionFailure("Missing Halloween default for theme role: \(role.rawValue)")
        }
        return fallback
    }

    public mutating func setColor(_ color: NBThemeColor, for role: NBThemeRole) {
        colors[role.rawValue] = color
    }

    public static let halloween: NBThemeProfile = {
        func rgb(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Double = 1) -> NBThemeColor {
            NBThemeColor(
                red: Double(red) / 255,
                green: Double(green) / 255,
                blue: Double(blue) / 255,
                alpha: alpha
            )
        }

        let background = rgb(0x07, 0x0B, 0x08)
        let elevated = rgb(0x10, 0x17, 0x10)
        let elevatedHigh = rgb(0x17, 0x21, 0x17)
        let accent = rgb(0x4C, 0xE6, 0x4C)
        let pumpkin = rgb(0xFF, 0x7A, 0x18)
        let blood = rgb(0xE0, 0x1B, 0x1B)
        let purple = rgb(0xB1, 0x4C, 0xFF)
        let text = rgb(0xA8, 0xE6, 0xA8)
        let secondary = rgb(0x7E, 0x92, 0x7F)
        let tertiary = rgb(0x5B, 0x6A, 0x5C)

        var values: [String: NBThemeColor] = [:]
        func set(_ role: NBThemeRole, _ color: NBThemeColor) {
            values[role.rawValue] = color
        }

        set(.background, background)
        set(.elevated, elevated)
        set(.elevatedHigh, elevatedHigh)
        set(.controlFill, rgb(0x18, 0x24, 0x18))
        set(.controlFillStrong, rgb(0x20, 0x30, 0x20))
        set(.overlaySurface, rgb(0x12, 0x1A, 0x12, 0.96))
        set(.overlayScrim, rgb(0x00, 0x00, 0x00, 0.25))
        set(.imageScrim, rgb(0x00, 0x00, 0x00, 0.60))
        set(.mask, rgb(0x00, 0x00, 0x00, 1.00))
        set(.shadow, rgb(0x00, 0x00, 0x00, 0.16))
        set(.text, text)
        set(.textSecondary, secondary)
        set(.textTertiary, tertiary)
        set(.disabledText, rgb(0x61, 0x70, 0x62, 0.80))
        set(.onAccent, rgb(0xFF, 0xFF, 0xFF))
        set(.overlayText, rgb(0xFF, 0xFF, 0xFF))

        set(.accent, accent)
        set(.secondaryAccent, pumpkin)
        set(.tertiaryAccent, purple)
        set(.title, purple)
        set(.selection, purple)
        set(.heading, pumpkin)
        set(.headingFill, rgb(0xFF, 0x7A, 0x18, 0.16))
        set(.separator, rgb(0x4C, 0xE6, 0x4C, 0.18))
        set(.border, rgb(0x4C, 0xE6, 0x4C, 0.30))
        set(.imageBorder, rgb(0x7E, 0x92, 0x7F, 0.30))
        set(.success, accent)
        set(.warning, pumpkin)
        set(.danger, blood)
        set(.expired, rgb(0x80, 0x80, 0x80))

        set(.navigationBackground, background)
        set(.navigationTitle, purple)
        set(.navigationText, text)
        set(.navigationTint, accent)
        set(.navigationShadow, rgb(0x00, 0x00, 0x00, 0))
        set(.tabBackground, elevated)
        set(.tabSelected, accent)
        set(.tabUnselected, pumpkin)
        set(.tabShadow, rgb(0x00, 0x00, 0x00, 0))
        set(.searchBackground, elevated)
        set(.searchText, text)
        set(.searchPlaceholder, secondary)
        set(.searchTint, accent)
        set(.segmentBackground, elevated)
        set(.segmentSelectedBackground, purple)
        set(.segmentText, secondary)
        set(.segmentSelectedText, rgb(0xFF, 0xFF, 0xFF))
        set(.barButtonTint, accent)

        set(.liveActivityBackground, rgb(0x00, 0x00, 0x00, 0.55))
        set(.liveActivityActionText, text)
        set(.liveActivityPrimaryText, text)
        set(.liveActivitySecondaryText, secondary)
        set(.liveActivityRunning, accent)
        set(.liveActivityIdle, pumpkin)

        set(.reportBackground, background)
        set(.reportCard, elevated)
        set(.reportBorder, rgb(0x4C, 0xE6, 0x4C, 0.20))
        set(.reportText, text)
        set(.reportDim, secondary)
        set(.reportAccent, accent)
        set(.reportSuccess, accent)
        set(.reportWarning, pumpkin)
        set(.reportDanger, blood)
        set(.reportSuccessFill, rgb(0x4C, 0xE6, 0x4C, 0.12))
        set(.reportWarningFill, rgb(0xFF, 0x7A, 0x18, 0.12))
        set(.reportDangerFill, rgb(0xE0, 0x1B, 0x1B, 0.12))
        set(.reportTapHighlight, rgb(0x00, 0x00, 0x00, 0.00))
        set(.reportPink, rgb(0xF4, 0x72, 0xB6))
        set(.reportPurple, purple)
        set(.reportBlue, rgb(0x60, 0xA5, 0xFA))
        set(.reportLime, rgb(0xA3, 0xE6, 0x35))
        set(.reportInteractiveFill, rgb(0xFF, 0xFF, 0xFF, 0.05))
        set(.reportInteractiveBorder, rgb(0xFF, 0xFF, 0xFF, 0.09))
        set(.reportSelectedFill, rgb(0xFF, 0xFF, 0xFF, 0.16))
        set(.reportSelectedText, rgb(0xFF, 0xFF, 0xFF))
        set(.reportDropdown, rgb(0x16, 0x16, 0x23, 0.96))
        set(.reportShadow, rgb(0x00, 0x00, 0x00, 0.50))

        return NBThemeProfile(id: Self.halloweenID, name: "Halloween", colors: values)
    }()
}

// MARK: - Persistent profile manager

public final class NBThemeManager: ObservableObject, @unchecked Sendable {
    public static let shared = NBThemeManager()

    private static let profilesKey = "Ksign.themeProfiles.v1"
    private static let selectedProfileKey = "Ksign.selectedThemeProfile.v1"

    @Published public private(set) var customThemes: [NBThemeProfile]
    @Published public private(set) var selectedThemeID: String

    private let defaults: UserDefaults

    public var allThemes: [NBThemeProfile] {
        [NBThemeProfile.halloween] + customThemes
    }

    public var activeTheme: NBThemeProfile {
        profile(id: selectedThemeID) ?? .halloween
    }

    public var isActiveThemeBuiltIn: Bool {
        activeTheme.isBuiltIn
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let loadedThemes: [NBThemeProfile]
        if let data = defaults.data(forKey: Self.profilesKey),
           let themes = try? JSONDecoder().decode([NBThemeProfile].self, from: data) {
            loadedThemes = themes.filter { !$0.isBuiltIn }
        } else {
            loadedThemes = []
        }

        let stored = defaults.string(forKey: Self.selectedProfileKey) ?? NBThemeProfile.halloweenID
        let initialThemeID: String
        if stored == NBThemeProfile.halloweenID || loadedThemes.contains(where: { $0.id == stored }) {
            initialThemeID = stored
        } else {
            initialThemeID = NBThemeProfile.halloweenID
        }

        // Initialize the @Published backing storage directly so Swift 6 does not
        // treat the wrapped-property access as a use of `self` before every
        // stored property has been initialized.
        self._customThemes = Published(initialValue: loadedThemes)
        self._selectedThemeID = Published(initialValue: initialThemeID)
    }

    public func profile(id: String) -> NBThemeProfile? {
        if id == NBThemeProfile.halloweenID { return .halloween }
        return customThemes.first { $0.id == id }
    }

    @discardableResult
    public func createTheme(name: String, copying source: NBThemeProfile? = nil) -> NBThemeProfile {
        let base = source ?? activeTheme
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Custom Theme" : trimmed
        let theme = NBThemeProfile(name: finalName, colors: base.colors)
        customThemes.append(theme)
        selectedThemeID = theme.id
        persist()
        return theme
    }

    @discardableResult
    public func duplicateActiveTheme() -> NBThemeProfile {
        createTheme(name: "\(activeTheme.name) Copy", copying: activeTheme)
    }

    public func selectTheme(id: String) {
        guard profile(id: id) != nil, selectedThemeID != id else { return }
        selectedThemeID = id
        persist()
    }

    public func renameActiveTheme(_ name: String) {
        renameTheme(id: selectedThemeID, name: name)
    }

    public func renameTheme(id: String, name: String) {
        guard id != NBThemeProfile.halloweenID,
              let index = customThemes.firstIndex(where: { $0.id == id }) else { return }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, customThemes[index].name != trimmed else { return }
        var theme = customThemes[index]
        theme.name = trimmed
        customThemes[index] = theme
        persist()
    }

    public func setColor(_ color: NBThemeColor, for role: NBThemeRole) {
        setColor(color, for: role, in: selectedThemeID)
    }

    public func setColor(_ color: NBThemeColor, for role: NBThemeRole, in themeID: String) {
        guard themeID != NBThemeProfile.halloweenID,
              let index = customThemes.firstIndex(where: { $0.id == themeID }) else { return }

        var theme = customThemes[index]
        guard theme.color(for: role) != color else { return }
        theme.setColor(color, for: role)
        customThemes[index] = theme
        persist()
    }

    public func resetActiveThemeColors() {
        resetThemeColors(id: selectedThemeID)
    }

    public func resetThemeColors(id: String) {
        guard id != NBThemeProfile.halloweenID,
              let index = customThemes.firstIndex(where: { $0.id == id }) else { return }

        var theme = customThemes[index]
        theme.colors = NBThemeProfile.halloween.colors
        customThemes[index] = theme
        persist()
    }

    public func deleteActiveTheme() {
        deleteTheme(id: selectedThemeID)
    }

    public func deleteTheme(id: String) {
        guard id != NBThemeProfile.halloweenID else { return }
        customThemes.removeAll { $0.id == id }
        if selectedThemeID == id {
            selectedThemeID = NBThemeProfile.halloweenID
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(customThemes) {
            defaults.set(data, forKey: Self.profilesKey)
        }
        defaults.set(selectedThemeID, forKey: Self.selectedProfileKey)
    }
}

// MARK: - Compatibility facade

public enum NBHalloween {
    public static func themeColor(_ role: NBThemeRole) -> NBThemeColor {
        NBThemeManager.shared.activeTheme.color(for: role)
    }

    public static func color(_ role: NBThemeRole) -> Color {
        themeColor(role).color
    }

    public static var background: Color { color(.background) }
    public static var elevated: Color { color(.elevated) }
    public static var elevatedHigh: Color { color(.elevatedHigh) }
    public static var controlFill: Color { color(.controlFill) }
    public static var controlFillStrong: Color { color(.controlFillStrong) }
    public static var overlaySurface: Color { color(.overlaySurface) }
    public static var overlayScrim: Color { color(.overlayScrim) }
    public static var imageScrim: Color { color(.imageScrim) }
    public static var mask: Color { color(.mask) }
    public static var shadow: Color { color(.shadow) }

    public static var accent: Color { color(.accent) }
    public static var pumpkin: Color { color(.secondaryAccent) }
    public static var blood: Color { color(.danger) }
    public static var neonPurple: Color { color(.tertiaryAccent) }

    public static var title: Color { color(.title) }
    public static var selection: Color { color(.selection) }
    public static var text: Color { color(.text) }
    public static var textSecondary: Color { color(.textSecondary) }
    public static var textTertiary: Color { color(.textTertiary) }
    public static var disabledText: Color { color(.disabledText) }
    public static var onAccent: Color { color(.onAccent) }
    public static var overlayText: Color { color(.overlayText) }
    public static var hairline: Color { color(.separator) }
    public static var border: Color { color(.border) }
    public static var imageBorder: Color { color(.imageBorder) }
    public static var heading: Color { color(.heading) }
    public static var headingFill: Color { color(.headingFill) }
    public static var ok: Color { color(.success) }
    public static var warning: Color { color(.warning) }
    public static var danger: Color { color(.danger) }
    public static var expired: Color { color(.expired) }

    public static var liveActivityBackground: Color { color(.liveActivityBackground) }
    public static var liveActivityActionText: Color { color(.liveActivityActionText) }
    public static var liveActivityPrimaryText: Color { color(.liveActivityPrimaryText) }
    public static var liveActivitySecondaryText: Color { color(.liveActivitySecondaryText) }
    public static var liveActivityRunning: Color { color(.liveActivityRunning) }
    public static var liveActivityIdle: Color { color(.liveActivityIdle) }

#if canImport(UIKit)
    public static func uiColor(_ role: NBThemeRole) -> UIColor {
        themeColor(role).uiColor
    }

    public static var uiBackground: UIColor { uiColor(.background) }
    public static var uiElevated: UIColor { uiColor(.elevated) }
    public static var uiElevatedHigh: UIColor { uiColor(.elevatedHigh) }
    public static var uiAccent: UIColor { uiColor(.accent) }
    public static var uiPumpkin: UIColor { uiColor(.secondaryAccent) }
    public static var uiBlood: UIColor { uiColor(.danger) }
    public static var uiPurple: UIColor { uiColor(.tertiaryAccent) }
    public static var uiText: UIColor { uiColor(.text) }
    public static var uiTextSecondary: UIColor { uiColor(.textSecondary) }
    public static var uiTitle: UIColor { uiColor(.title) }
#endif
}

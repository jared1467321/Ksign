import Foundation

extension NBThemeProfile {
    public static let liquidGlass = NBThemeProfile(
        id: liquidGlassID,
        name: "Aurora Glass",
        colors: glassPalette(isDark: true),
        lightColors: glassPalette(isDark: false)
    )

    // Text uses neutral ink/frost instead of the aurora's saturated colors.
    // Every role is covered, including UIKit, reports and the Live Activity.
    static func glassPalette(isDark: Bool) -> [String: NBThemeColor] {
        func hex(_ value: UInt32, _ alpha: Double = 1) -> NBThemeColor {
            NBThemeColor(red: Double((value >> 16) & 255) / 255,
                         green: Double((value >> 8) & 255) / 255,
                         blue: Double(value & 255) / 255, alpha: alpha)
        }
        func pair(_ dark: UInt32, _ light: UInt32, _ alpha: Double = 1) -> NBThemeColor {
            hex(isDark ? dark : light, alpha)
        }
        return Dictionary(uniqueKeysWithValues: NBThemeRole.allCases.map { role in
            let color: NBThemeColor
            switch role {
            case .background, .navigationBackground, .reportBackground:
                color = pair(0x0E0F11, 0xF3F5FB)
            case .elevated, .searchBackground, .segmentBackground, .tabBackground, .reportCard:
                color = pair(0x1A1C20, 0xFFFFFF)
            case .elevatedHigh, .controlFillStrong:
                color = pair(0x24262A, 0xE5E9F3)
            case .controlFill:
                color = pair(0x20232B, 0xEBEEF7)
            case .overlaySurface, .reportDropdown:
                color = pair(0x171A24, 0xFAFBFF, 0.96)
            case .overlayScrim:
                color = hex(0, isDark ? 0.28 : 0.12)
            case .imageScrim:
                color = hex(0, 0.60)
            case .mask:
                color = hex(0)
            case .shadow:
                color = hex(0, isDark ? 0.24 : 0.10)
            case .text, .searchText, .navigationText, .reportText:
                color = pair(0xF0F5FF, 0x182034)
            case .textSecondary, .searchPlaceholder, .segmentText, .tabUnselected, .reportDim:
                color = pair(0xB8B9CD, 0x1A2335)
            case .textTertiary, .disabledText, .expired:
                color = pair(0x9397AB, 0x626C80)
            case .onAccent:
                color = pair(0x281B04, 0xFFFFFF)
            case .overlayText, .segmentSelectedText, .reportSelectedText:
                color = hex(0xFFFFFF)
            case .accent, .navigationTint, .searchTint, .tabSelected, .barButtonTint, .reportAccent:
                color = pair(0xFFD273, 0x332100)
            case .secondaryAccent, .warning, .reportWarning:
                color = pair(0xF5A623, 0x805100)
            case .tertiaryAccent, .title, .navigationTitle, .reportPurple:
                color = pair(0xC7B8E0, 0x48215D)
            case .heading:
                color = pair(0xD9D9E8, 0x26324B)
            case .selection, .segmentSelectedBackground:
                color = pair(0x665485, 0x715494)
            case .headingFill:
                color = pair(0xC7B8E0, 0x65408B, 0.16)
            case .separator, .imageBorder, .reportBorder:
                color = pair(0xFFFFFF, 0x263758, isDark ? 0.14 : 0.16)
            case .border, .reportInteractiveBorder:
                color = pair(0xFFFFFF, 0x263758, isDark ? 0.26 : 0.22)
            case .navigationShadow, .tabShadow, .reportTapHighlight:
                color = hex(0, 0)
            case .success, .reportSuccess:
                color = pair(0x82E8BC, 0x146341)
            case .danger, .reportDanger:
                color = pair(0xFF9A91, 0xA52622)
            // Dynamic Island always has a dark backing, even in Light mode.
            case .liveActivityBackground:
                color = hex(0x0E0F11, 0.88)
            case .liveActivityActionText, .liveActivityPrimaryText:
                color = hex(0xF0F5FF)
            case .liveActivitySecondaryText:
                color = hex(0xB8B9CD)
            case .liveActivityRunning:
                color = hex(0x82E8BC)
            case .liveActivityIdle:
                color = hex(0xFFD273)
            case .reportSuccessFill:
                color = pair(0x82E8BC, 0x146341, 0.13)
            case .reportWarningFill:
                color = pair(0xF5A623, 0x805100, 0.13)
            case .reportDangerFill:
                color = pair(0xFF9A91, 0xA52622, 0.13)
            case .reportPink:
                color = pair(0xF4A8D2, 0x962866)
            case .reportBlue:
                color = pair(0xA0C8FA, 0x235A9B)
            case .reportLime:
                color = pair(0xB6E66E, 0x486614)
            case .reportInteractiveFill:
                color = pair(0xFFFFFF, 0x263758, 0.07)
            case .reportSelectedFill:
                color = pair(0x665485, 0x715494)
            case .reportShadow:
                color = hex(0, isDark ? 0.40 : 0.12)
            }
            return (role.rawValue, color)
        })
    }
}

//
//  AppearanceView.swift
//  Ksign
//
//  Theme profile selection and editing.
//

import SwiftUI
import UIKit
import NimbleViews
import NimbleExtensions

struct AppearanceView: View {
    @AppStorage("Feather.userInterfaceStyle") private var _userInterfaceStyle: Int = UIUserInterfaceStyle.unspecified.rawValue
    @AppStorage("Feather.storeCellAppearance") private var _storeCellAppearance: Int = 1

    @StateObject private var themeManager = NBThemeManager.shared
    @State private var showDeleteConfirmation = false
    @State private var showResetConfirmation = false

    private let _storeCellAppearanceMethods: [String] = [
        .localized("Standard"),
        .localized("Big Description")
    ]

    var body: some View {
        NBList(.localized("Appearance")) {
            Section(footer: Text(.localized("Ksign is dark-only."))) {
                Picker(.localized("Appearance"), selection: $_userInterfaceStyle) {
                    ForEach(UIUserInterfaceStyle.allCases.sorted(by: { $0.rawValue < $1.rawValue }), id: \.rawValue) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(true)
            }

            NBSection(.localized("Theme Profiles")) {
                Picker(.localized("Active Theme"), selection: _themeSelection) {
                    ForEach(themeManager.allThemes) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }

                _themePreview(themeManager.activeTheme)

                if themeManager.isActiveThemeBuiltIn {
                    Text(.localized("Halloween is the built-in default. Duplicate it or create a theme to customize every color role."))
                        .font(.footnote)
                        .foregroundStyle(NBHalloween.textSecondary)
                } else {
                    NavigationLink(destination: ThemeProfileEditorView(themeID: themeManager.selectedThemeID)) {
                        Label(.localized("Customize Colors"), systemImage: "paintpalette")
                    }
                }

                Button {
                    let number = themeManager.customThemes.count + 1
                    themeManager.createTheme(
                        name: String.localizedStringWithFormat(String.localized("Custom Theme %d"), number),
                        copying: themeManager.activeTheme
                    )
                } label: {
                    Label(.localized("Create Theme"), systemImage: "plus")
                }

                Button {
                    themeManager.duplicateActiveTheme()
                } label: {
                    Label(.localized("Duplicate Theme"), systemImage: "square.on.square")
                }

                if !themeManager.isActiveThemeBuiltIn {
                    Button {
                        showResetConfirmation = true
                    } label: {
                        Label(.localized("Reset Colors to Halloween"), systemImage: "arrow.counterclockwise")
                    }

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label(.localized("Delete Theme"), systemImage: "trash")
                    }
                }
            } footer: {
                Text(.localized("Theme profiles are stored on this device. The Halloween profile always remains available as the factory default."))
            }
            // Keep profile mutations out of the temporary editing session.
            .allowsHitTesting(!themeManager.isColorPreviewActive)

            NBSection(.localized("Sources")) {
                _storePreview()
                Picker(.localized("Store Cell Appearance"), selection: $_storeCellAppearance) {
                    ForEach(_storeCellAppearanceMethods.indices, id: \.self) { index in
                        Text(_storeCellAppearanceMethods[index]).tag(index)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .onChange(of: _userInterfaceStyle) { value in
            if let style = UIUserInterfaceStyle(rawValue: value) {
                UIApplication.topViewController()?.view.window?.overrideUserInterfaceStyle = style
            }
        }
        .confirmationDialog(
            .localized("Reset this theme's colors?"),
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(.localized("Reset Colors"), role: .destructive) {
                themeManager.resetActiveThemeColors()
            }
            Button(.localized("Cancel"), role: .cancel) { }
        } message: {
            Text(.localized("The profile name stays the same, but every customizable color returns to the Halloween defaults."))
        }
        .confirmationDialog(
            .localized("Delete this theme?"),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(.localized("Delete Theme"), role: .destructive) {
                themeManager.deleteActiveTheme()
            }
            Button(.localized("Cancel"), role: .cancel) { }
        }
    }

    private var _themeSelection: Binding<String> {
        Binding(
            get: { themeManager.selectedThemeID },
            set: { themeManager.selectTheme(id: $0) }
        )
    }

    @ViewBuilder
    private func _themePreview(_ theme: NBThemeProfile) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(theme.name)
                    .font(.headline)
                    .foregroundStyle(NBHalloween.text)
                    .nbThemeInspectorTarget(.text)
                Text(theme.isBuiltIn ? String.localized("Built-in") : String.localized("Custom"))
                    .font(.caption)
                    .foregroundStyle(NBHalloween.textSecondary)
                    .nbThemeInspectorTarget(.textSecondary)
            }

            Spacer()

            HStack(spacing: 5) {
                ForEach(
                    [NBThemeRole.accent, .secondaryAccent, .tertiaryAccent, .success, .danger],
                    id: \.self
                ) { role in
                    Circle()
                        .fill(theme.color(for: role).color)
                        .frame(width: 19, height: 19)
                        .overlay {
                            Circle().stroke(NBHalloween.imageBorder, lineWidth: 0.5)
                        }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func _storePreview() -> some View {
        VStack {
            HStack(spacing: 9) {
                Image(uiImage: (UIImage(named: Bundle.main.iconFileName ?? ""))!)
                    .appIconStyle(size: 57)

                NBTitleWithSubtitleView(
                    title: Bundle.main.name,
                    subtitle: "\(Bundle.main.version) • " + .localized("An awesome application"),
                    linelimit: 0
                )
            }

            if _storeCellAppearance != 0 {
                Text(.localized("An awesome application"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.subheadline)
                    .foregroundStyle(NBHalloween.textSecondary)
                    .lineLimit(18)
                    .padding(.top, 2)
            }
        }
        .animation(.spring, value: _storeCellAppearance)
    }
}

private struct ThemeProfileEditorView: View {
    let themeID: String

    @StateObject private var themeManager = NBThemeManager.shared
    @State private var name = ""
    @State private var searchText = ""
    @State private var inspectedRole: NBThemeRole?

    private var theme: NBThemeProfile {
        themeManager.profile(id: themeID) ?? .halloween
    }

    var body: some View {
        NBList(.localized("Customize Theme")) {
            NBSection(.localized("Profile")) {
                TextField(.localized("Theme Name"), text: $name)
                    .textInputAutocapitalization(.words)
                    .onSubmit(_saveName)
                    .onChange(of: name) { _ in _saveName() }
            }

            if searchText.isEmpty {
                NBSection(.localized("Live Preview")) {
                    _livePreview

                    Text(.localized("This preview shows the main app colors. Each setting below also explains where it appears, including colors used on other screens."))
                        .font(.footnote)
                        .foregroundStyle(NBHalloween.textSecondary)
                }
            }

            ForEach(NBThemeRole.Category.allCases) { category in
                if !_visibleRoles(in: category).isEmpty {
                    NBSection(category.rawValue) {
                        ForEach(_visibleRoles(in: category)) { role in
                            HStack(spacing: 12) {
                                ColorPicker(selection: _binding(for: role), supportsOpacity: true) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(role.displayName)
                                            .font(.body)
                                        Text(role.usageDescription)
                                            .font(.caption)
                                            .foregroundStyle(NBHalloween.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.vertical, 3)
                                }
                                .accessibilityHint(Text(role.usageDescription))

                                Button {
                                    inspectedRole = role
                                } label: {
                                    Image(systemName: "location.viewfinder")
                                        .font(.body.weight(.semibold))
                                        .frame(width: 36, height: 36)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Show and edit \(role.displayName) in context")
                                .accessibilityHint("Opens a live screen or labeled example with a temporary color editor")
                            }
                        }
                    }
                }
            }

            if !searchText.isEmpty && NBThemeRole.Category.allCases.allSatisfy({ _visibleRoles(in: $0).isEmpty }) {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .searchable(text: $searchText, prompt: .localized("Find a color or screen element"))
        .fullScreenCover(item: $inspectedRole, onDismiss: {
            themeManager.cancelColorPreview(in: themeID)
        }) { role in
            ThemeColorInspectorView(role: role, themeID: themeID)
        }
        .onAppear {
            name = theme.name
            if themeManager.selectedThemeID != themeID {
                themeManager.selectTheme(id: themeID)
            }
        }
        .onDisappear {
            _saveName()
        }
    }

    private func _visibleRoles(in category: NBThemeRole.Category) -> [NBThemeRole] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return NBThemeRole.allCases.filter { role in
            guard role.category == category else { return false }
            return query.isEmpty
                || category.rawValue.localizedCaseInsensitiveContains(query)
                || role.displayName.localizedCaseInsensitiveContains(query)
                || role.usageDescription.localizedCaseInsensitiveContains(query)
        }
    }

    // The ordinary editor and the temporary in-context editor share these
    // swatches. The active theme's unsaved preview is reflected here too.
    private func _previewColor(_ role: NBThemeRole) -> Color {
        themeManager.selectedThemeID == themeID
            ? themeManager.activeColor(for: role).color
            : theme.color(for: role).color
    }

    private var _livePreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(.localized("Example screen"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(_previewColor(.navigationText))
                Spacer()
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(_previewColor(.navigationTint))
            }

            Text(.localized("Your Library"))
                .font(.title3.weight(.bold))
                .foregroundStyle(_previewColor(.title))

            HStack(spacing: 10) {
                Image(systemName: "app.fill")
                    .font(.title2)
                    .foregroundStyle(_previewColor(.accent))
                    .frame(width: 42, height: 42)
                    .background(_previewColor(.controlFill), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(.localized("Example App"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(_previewColor(.text))
                    Text(.localized("Secondary information"))
                        .font(.caption)
                        .foregroundStyle(_previewColor(.textSecondary))
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(_previewColor(.success))
            }
            .padding(10)
            .background(_previewColor(.elevated), in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Text(.localized("Example action"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(_previewColor(.onAccent))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(_previewColor(.accent), in: Capsule())
                Spacer()
                Text(.localized("In progress"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(_previewColor(.warning))
            }

            Rectangle()
                .fill(_previewColor(.separator))
                .frame(height: 1)

            HStack {
                Label(.localized("Library"), systemImage: "square.grid.2x2.fill")
                    .foregroundStyle(_previewColor(.tabSelected))
                Spacer()
                Label(.localized("Settings"), systemImage: "gearshape")
                    .foregroundStyle(_previewColor(.tabUnselected))
            }
            .font(.caption)
            .padding(9)
            .background(_previewColor(.tabBackground), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(14)
        .background(_previewColor(.background), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(_previewColor(.border), lineWidth: 1)
        }
    }

    private func _saveName() {
        themeManager.renameTheme(id: themeID, name: name)
    }

    private func _binding(for role: NBThemeRole) -> Binding<Color> {
        Binding(
            get: {
                themeManager.profile(id: themeID)?.color(for: role).color
                    ?? NBThemeProfile.halloween.color(for: role).color
            },
            set: { newColor in
                themeManager.setColor(
                    NBThemeColor(uiColor: UIColor(newColor)),
                    for: role,
                    in: themeID
                )
            }
        )
    }
}

// Keep explanations beside the pickers instead of requiring a separate help
// screen. Search also matches these descriptions (e.g. "tab bar" or "report").
extension NBThemeRole {
    var usageDescription: String {
        switch self {
        case .background: return "Background behind the app's lists and screens."
        case .elevated: return "List rows, cards, and other surfaces above the page."
        case .elevatedHigh: return "Reserved raised-surface color; no existing app screen currently uses it."
        case .controlFill: return "Background of small controls, buttons, and icon tiles."
        case .controlFillStrong: return "Reserved strong control fill; no existing app screen currently uses it."
        case .overlaySurface: return "Floating panels, popovers, and badges shown over content."
        case .overlayScrim: return "Dim layer behind an open overlay or drawer."
        case .imageScrim: return "Dark gradient over images so captions remain readable."
        case .mask: return "Mask and fade effects around artwork and progress views."
        case .shadow: return "Soft shadows under floating content and cards."

        case .text: return "Main text in lists, cards, and screen content."
        case .textSecondary: return "Subtitles, descriptions, and less prominent labels."
        case .textTertiary: return "Separator between IPA Vault download speed and stream count during an active download."
        case .disabledText: return "Labels for unavailable or disabled actions."
        case .onAccent: return "Text and icons placed on solid accent-colored buttons."
        case .overlayText: return "Text and outlines placed on top of images or overlays."

        case .accent: return "Main button, icon, link, and interactive highlight color."
        case .secondaryAccent: return "Secondary accent shown in theme swatches; not currently used by another app screen."
        case .tertiaryAccent: return "Third highlight color used for purple-style details."
        case .title: return "Large title in the theme editor preview; navigation titles have their own color."
        case .selection: return "Reserved selection color; no existing app screen currently uses it."
        case .heading: return "Section titles above groups of settings or list rows."
        case .headingFill: return "Background behind the small badges beside section titles."
        case .separator: return "Thin divider lines between rows and content."
        case .border: return "Outline of the theme editor preview; app icons and reports use separate borders."
        case .imageBorder: return "Fine outlines around app icons and image thumbnails."
        case .success: return "Successful and completed states, such as checkmarks."
        case .warning: return "Warnings and operations that are still in progress."
        case .danger: return "Errors, destructive actions, and failed states."
        case .expired: return "Expired certificates and other inactive states."

        case .navigationBackground: return "Background of the top navigation bar."
        case .navigationTitle: return "Large navigation-bar title when a screen uses large titles."
        case .navigationText: return "Small, centered title in the top navigation bar."
        case .navigationTint: return "Back arrows and tinted navigation-bar controls."
        case .navigationShadow: return "Hairline or shadow below the top navigation bar."
        case .tabBackground: return "Background of the bottom tab bar."
        case .tabSelected: return "Icon and label of the currently selected bottom tab."
        case .tabUnselected: return "Icons and labels of inactive bottom tabs."
        case .tabShadow: return "Hairline or shadow above the bottom tab bar."
        case .searchBackground: return "Fill inside the search field."
        case .searchText: return "Text entered into the search field."
        case .searchPlaceholder: return "Hint text shown in an empty search field."
        case .searchTint: return "Search cursor and the search field's tinted controls."
        case .segmentBackground: return "Background behind all options in a segmented picker."
        case .segmentSelectedBackground: return "Fill of the active option in a segmented picker."
        case .segmentText: return "Labels of unselected segmented-picker options."
        case .segmentSelectedText: return "Label of the selected segmented-picker option."
        case .barButtonTint: return "Text and icons of top-bar action buttons."

        case .liveActivityBackground: return "Background of the Live Activity and Dynamic Island."
        case .liveActivityActionText: return "Text of system-style actions in the Live Activity."
        case .liveActivityPrimaryText: return "Main status text in the Live Activity."
        case .liveActivitySecondaryText: return "Secondary details in the Live Activity."
        case .liveActivityRunning: return "Indicator shown while a Live Activity is running."
        case .liveActivityIdle: return "Indicator shown while a Live Activity is idle."

        case .reportBackground: return "Page background of a Crypt Check HTML report."
        case .reportCard: return "Cards and raised sections inside Crypt Check reports."
        case .reportBorder: return "Outlines around report cards and report sections."
        case .reportText: return "Main text inside Crypt Check reports."
        case .reportDim: return "Muted captions and secondary text in reports."
        case .reportAccent: return "Primary highlights and links inside reports."
        case .reportSuccess: return "Successful results and positive report indicators."
        case .reportWarning: return "Warnings and caution indicators in reports."
        case .reportDanger: return "Errors and negative result indicators in reports."
        case .reportSuccessFill: return "Light background behind successful result badges."
        case .reportWarningFill: return "Light background behind warning badges."
        case .reportDangerFill: return "Light background behind error badges."
        case .reportTapHighlight: return "Brief highlight when tapping interactive report content."
        case .reportPink: return "Pink-colored charts and decorative report highlights."
        case .reportPurple: return "Purple-colored charts and decorative report highlights."
        case .reportBlue: return "Blue-colored charts and decorative report highlights."
        case .reportLime: return "Lime-colored charts and decorative report highlights."
        case .reportInteractiveFill: return "Fill of filter pills and other interactive report controls."
        case .reportInteractiveBorder: return "Outline of report filter pills and interactive controls."
        case .reportSelectedFill: return "Background of a selected report filter or option."
        case .reportSelectedText: return "Text of a selected report filter or option."
        case .reportDropdown: return "Background of dropdown menus inside reports."
        case .reportShadow: return "Shadows cast by report cards and floating menus."
        }
    }
}

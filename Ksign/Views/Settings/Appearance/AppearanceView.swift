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
                Text(theme.isBuiltIn ? String.localized("Built-in") : String.localized("Custom"))
                    .font(.caption)
                    .foregroundStyle(NBHalloween.textSecondary)
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

            ForEach(NBThemeRole.Category.allCases) { category in
                NBSection(category.rawValue) {
                    ForEach(NBThemeRole.allCases.filter { $0.category == category }) { role in
                        ColorPicker(
                            role.displayName,
                            selection: _binding(for: role),
                            supportsOpacity: true
                        )
                    }
                }
            }
        }
        .onAppear {
            name = theme.name
            if themeManager.selectedThemeID != themeID {
                themeManager.selectTheme(id: themeID)
            }
        }
        .onDisappear(_saveName)
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

//
//  AppearanceView.swift
//  Feather
//
//  Created by samara on 7.05.2025.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct AppearanceView: View {
    @AppStorage("Feather.userInterfaceStyle") private var _userIntefacerStyle: Int = UIUserInterfaceStyle.unspecified.rawValue
    
	@AppStorage("Feather.libraryCellAppearance") private var _libraryCellAppearance: Int = 0
	
	private let _libraryCellAppearanceMethods: [String] = [
		.localized("Standard"),
		.localized("Pill")
	]
	
	@AppStorage("Feather.storeCellAppearance") private var _storeCellAppearance: Int = 1
	
	private let _storeCellAppearanceMethods: [String] = [
		.localized("Standard"),
		.localized("Big Description")
	]
	
	@AppStorage("Feather.accentColor") private var _selectedAccentColor: Int = 0
	@StateObject private var accentColorManager = AccentColorManager.shared
    
	// Order must stay in lockstep with AccentColorManager._accentColors —
	// the picker binds to the raw index, so a mismatch here shows one swatch
	// and applies another.
	private let _accentColors: [(name: String, color: Color)] = [
		(.localized("Neon Green"), NBHalloween.accent),
		(.localized("Pumpkin"), NBHalloween.pumpkin),
		(.localized("Blood"), NBHalloween.blood),
		(.localized("Ksign Blue"), Color(red: 0x53/255, green: 0x94/255, blue: 0xF7/255)),
		(.localized("Cherry"), Color(red: 0xFF/255, green: 0x8B/255, blue: 0x92/255)),
		(.localized("Red"), .red),
		(.localized("Orange"), .orange),
		(.localized("Yellow"), .yellow),
		(.localized("Green"), .green),
		(.localized("Blue"), .blue),
		(.localized("Purple"), .purple),
		(.localized("Pink"), .pink),
		(.localized("Indigo"), .indigo),
		(.localized("Mint"), .mint),
		(.localized("Cyan"), .cyan),
		(.localized("Teal"), .teal)
	]
	
	private var currentAccentColor: Color {
		accentColorManager.currentAccentColor
	}

    var body: some View {
        NBList(.localized("Appearance")) {
            
            // Info.plist pins UIUserInterfaceStyle to Dark, which UIKit applies
            // before any of this runs and which nothing here can override.
            // Leaving the control live would let it save a preference that
            // never takes effect, so it is shown disabled rather than removed —
            // flipping the Info.plist key back re-enables it.
            Section(footer: Text(.localized("Ksign is dark-only."))) {
                Picker(.localized("Appearance"), selection: $_userIntefacerStyle) {
                    ForEach(UIUserInterfaceStyle.allCases.sorted(by: { $0.rawValue < $1.rawValue }), id: \.rawValue) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(true)
            }
			
			NBSection(.localized("Sources")) {
                _storePreview()
				Picker(.localized("Store Cell Appearance"), selection: $_storeCellAppearance) {
					ForEach(_storeCellAppearanceMethods.indices, id: \.description) { index in
						Text(_storeCellAppearanceMethods[index]).tag(index)
					}
				}
				.pickerStyle(.inline)
                .labelsHidden()
			}
			
			NBSection(.localized("Accent Color")) {
				_accentColorPreview()
				Picker(.localized("Accent Color"), selection: $_selectedAccentColor) {
					ForEach(_accentColors.indices, id: \.description) { index in
						HStack {
							Circle()
								.fill(_accentColors[index].color)
								.frame(width: 20, height: 20)
							Text(_accentColors[index].name)
						}
						.tag(index)
					}
				}
				.pickerStyle(.inline)
				.labelsHidden()
			}
		}
        .onChange(of: _userIntefacerStyle) { value in
            if let style = UIUserInterfaceStyle(rawValue: value) {
                UIApplication.topViewController()?.view.window?.overrideUserInterfaceStyle = style
            }
        }
		.onChange(of: _selectedAccentColor) { _ in
			accentColorManager.updateGlobalTintColor()
		}
    }
	
	@ViewBuilder
	private func _libraryPreview() -> some View {
		HStack(spacing: 9) {
			Image(uiImage: (UIImage(named: Bundle.main.iconFileName ?? ""))! )
				.appIconStyle(size: 57)
			
			NBTitleWithSubtitleView(
				title: Bundle.main.name,
				subtitle: "\(Bundle.main.version) • \(Bundle.main.bundleIdentifier ?? "")",
				linelimit: 0
			)
			
			FRExpirationPillView(
				title: .localized("Install"),
				showOverlay: _libraryCellAppearance == 0,
				expiration: Date.now.expirationInfo()
			).animation(.spring, value: _libraryCellAppearance)
		}
	}
    
    @ViewBuilder
    private func _storePreview() -> some View {
        VStack {
            HStack(spacing: 9) {
                Image(uiImage: (UIImage(named: Bundle.main.iconFileName ?? ""))! )
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
                    .foregroundStyle(.secondary)
                    .lineLimit(18)
                    .padding(.top, 2)
            }
        }
        .animation(.spring, value: _storeCellAppearance)
    }
	
	@ViewBuilder
	private func _accentColorPreview() -> some View {
		HStack(spacing: 9) {
			Circle()
				.fill(currentAccentColor)
				.frame(width: 57, height: 57)
			
			NBTitleWithSubtitleView(
				title: .localized("Accent Color"),
				subtitle: .localized("This is the current accent color"),
				linelimit: 0
			)
		}
	}
}

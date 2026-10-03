//
//  NBSheetButton.swift
//  NimbleKit
//
//  Created by samara on 8.05.2025.
//

import SwiftUI
import NimbleExtensions

public struct NBSheetButton: View {
	@ObservedObject private var themes = NBThemeManager.shared
	private var _title: String
    private let glassFillID = "NBSheetButton.glassFill"

    private var glassDefault: NBThemeColor {
        var color = themes.activeColor(for: .accent)
        color.alpha *= 0.9
        return color
    }

    private var glassFill: NBThemeColor {
        if themes.hasElementOverride(glassFillID) ||
            themes.isPreviewing(.accent, elementID: glassFillID, in: themes.selectedThemeID) {
            return themes.activeColor(for: .accent, elementID: glassFillID)
        }
        return glassDefault
    }
	
	public init(title: String) {
		self._title = title
	}
	
	public var body: some View {
        if #available(iOS 26.0, *) {
            Text(_title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
                .nbThemeForeground(.onAccent)
                .nbThemeInspectorTarget(.onAccent)
                .nbThemeInspectorTarget(.accent, elementID: glassFillID,
                    initialColor: glassDefault)
                .nbThemeClipShape(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                )
                .bold()
                .frame(height: 50)
                .glassEffect(.regular.tint(glassFill.color).interactive(), in: .rect(cornerRadius: 28))
                .padding()
        } else {
            Text(_title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .nbThemeBackground(.accent)
                .nbThemeForeground(.onAccent)
                .nbThemeInspectorTarget(.onAccent)
                .nbThemeInspectorTarget(.accent)
                .nbThemeClipShape(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .bold()
                .frame(height: 50)
                .padding()
        }
	}
}

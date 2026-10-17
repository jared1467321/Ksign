//
//  NBSheetButton.swift
//  NimbleKit
//
//  Created by samara on 8.05.2025.
//

import SwiftUI
import NimbleExtensions

public struct NBSheetButton: View {
	private var _title: String
    private let glassFillID = "NBSheetButton.glassFill"

	public init(title: String) {
		self._title = title
	}
	
	public var body: some View {
        Text(_title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .nbThemeForeground(.onAccent)
            .nbThemeInspectorTarget(.onAccent)
            .bold()
            .frame(height: 50)
            .nbThemeBackground(
                .accent, opacity: 0.9,
                in: RoundedRectangle(cornerRadius: 28, style: .continuous),
                elementID: glassFillID
            )
            .padding()
	}
}

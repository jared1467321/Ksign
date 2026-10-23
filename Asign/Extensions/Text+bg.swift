//
//  Text+bg.swift
//  Asign
//
//  Created by Nagata Asami on 14/8/25.
//

import SwiftUI
import NimbleExtensions

extension Text {
    func bg() -> some View {
        self.padding(.horizontal, 12)
            .frame(height: 29)
            .modifier(style())
            .nbThemeClipShape(Capsule())
    }
}

struct style: ViewModifier {
    func body(content: Content) -> some View {
        content
            .nbThemeBackground(.accent, opacity: 0.16, in: Capsule())
            .nbThemeOverlay(
                Capsule().nbThemeStroke(.accent, opacity: 0.35, lineWidth: 1)
            )
    }
}

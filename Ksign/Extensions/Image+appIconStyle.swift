//
//  Image+appIconStyle.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//

import SwiftUI
import NimbleExtensions

extension Image {
    /// Applies a certain style to an image
    func appIconStyle(
        size: CGFloat = 56,
        lineWidth: CGFloat = 1,
        isCircle: Bool = false,
        background: Color = .clear,
        backgroundRole: NBThemeRole? = nil
    ) -> some View {
        self.resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .nbThemeContentSurface()
            .nbThemeBackground {
                let shape = RoundedRectangle(cornerRadius: isCircle ? (size * 2) : (size * 0.2337), style: .continuous)
                if let backgroundRole {
                    shape.nbThemeFill(backgroundRole)
                } else {
                    shape.fill(background)
                }
            }
            .nbThemeOverlay {
                RoundedRectangle(cornerRadius: isCircle ? (size * 2) : (size * 0.2337), style: .continuous)
                    .nbThemeStrokeBorder(.imageBorder, lineWidth: lineWidth)
            }
            .nbThemeClipShape(RoundedRectangle(cornerRadius: isCircle ? (size * 2) : (size * 0.2337), style: .continuous))
    }
}

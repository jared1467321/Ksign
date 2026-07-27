//
//  Text+bg.swift
//  Ksign
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
            .clipShape(Capsule())
    }
}

struct style: ViewModifier {
    func body(content: Content) -> some View {
        // The glass variant was dropped on purpose. `glassEffect()` samples
        // what's behind it, and behind it is near-black, so the pill rendered
        // as the same neutral grey as stock iOS — one of the surfaces that kept
        // reading as untouched chrome. A flat accent wash is duller than glass
        // but it's actually the theme's colour.
        //
        // iOS 26 can tint glass via `.glassEffect(.regular.tint(_:))` if you
        // want the material back; it's left out here so the build doesn't hinge
        // on an API this project hasn't compiled against yet.
        content
            .background(NBHalloween.accent.opacity(0.16))
            .overlay(
                Capsule().stroke(NBHalloween.accent.opacity(0.35), lineWidth: 1)
            )
    }
}

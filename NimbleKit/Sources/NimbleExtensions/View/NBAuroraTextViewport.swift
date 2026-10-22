import SwiftUI

public extension View {
    /// Kept for source compatibility. Adaptive labels now use their native
    /// clipping ancestors; no asynchronously measured viewport is required.
    func nbThemeTextViewport() -> some View { self }
}

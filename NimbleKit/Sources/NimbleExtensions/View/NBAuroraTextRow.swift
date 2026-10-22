import SwiftUI

public extension View {
    /// Kept for source compatibility. Adaptive labels now track their actual
    /// window attachment directly, including scrolling and selection scales.
    func nbThemeTextRow() -> some View { self }
}

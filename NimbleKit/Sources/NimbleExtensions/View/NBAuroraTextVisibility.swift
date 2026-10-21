import Foundation

struct NBAuroraTextViewport: Equatable, Sendable {
    let clipping: CGRect
    let window: CGRect?
}

extension NBAuroraTextViewport {
    init(frame: CGRect, window: CGRect?, parent: Self? = nil) {
        // Content safe-area insets do not hide the list beneath glass bars.
        // Only the actual container and its parent constrain visible paint.
        self.init(clipping: parent.map { frame.intersection($0.clipping) } ?? frame,
                  window: window ?? parent?.window)
    }
}

/// Pure geometry policy shared by the text scopes and the scroll viewport.
enum NBAuroraTextVisibility {
    static func intersects(_ frame: CGRect, window: CGRect, clipping: CGRect? = nil) -> Bool {
        guard usable(frame), usable(window) else { return false }
        var visible = frame.intersection(window)
        if let clipping {
            guard usable(clipping) else { return false }
            visible = visible.intersection(clipping)
        }
        return usable(visible)
    }

    private static func usable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite
    }
}

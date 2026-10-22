import Foundation

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

    static func usable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite
    }
}

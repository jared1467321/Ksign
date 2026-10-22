import Foundation

struct NBAuroraTextViewport: Equatable, Sendable {
    let clipping: CGRect
    let window: CGRect?
    // A completed layout report also refreshes unchanged label positions.
    // This belongs to one viewport, rather than invalidating every tab.
    var measurementID: UUID? = nil

    var isReady: Bool {
        window.map { NBAuroraTextVisibility.intersects(clipping, window: $0) } == true
    }

    func clippedFrame(_ frame: CGRect) -> CGRect {
        // Preserve initial positions until both coordinate systems are ready.
        // The visibility check still prevents incomplete layouts activating ink.
        guard isReady, let window else { return frame }
        return NBAuroraTextVisibility.intersects(frame, window: window, clipping: clipping) ? frame : .null
    }
}

extension NBAuroraTextViewport {
    init(frame: CGRect, window: CGRect?, parent: Self? = nil, measurementID: UUID? = nil) {
        // Content safe-area insets do not hide the list beneath glass bars.
        // Only the actual container and its parent constrain visible paint.
        self.init(clipping: parent.map { frame.intersection($0.clipping) } ?? frame,
                  window: window ?? parent?.window, measurementID: measurementID)
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

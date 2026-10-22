import Foundation

/// SwiftUI owns the global frame; UIKit owns the reader's window position.
/// A deferred window report must never overwrite the frame measured in layout.
struct NBAuroraTextViewportMeasurement {
    private(set) var frame = CGRect.zero
    private(set) var window: CGRect?
    private var windowReport: CGRect?

    mutating func receiveFrame(_ frame: CGRect) {
        self.frame = frame
        // A window report can precede the first usable SwiftUI layout.
        if window == nil { resolveWindow() }
    }

    mutating func receiveWindow(origin: CGPoint, size: CGSize) {
        windowReport = CGRect(origin: origin, size: size)
        resolveWindow()
    }

    private mutating func resolveWindow() {
        guard NBAuroraTextVisibility.usable(frame), let report = windowReport,
              NBAuroraTextVisibility.usable(report) else { return }
        window = CGRect(x: frame.minX - report.minX, y: frame.minY - report.minY,
                        width: report.width, height: report.height)
    }
}

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

    static func usable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite
    }
}

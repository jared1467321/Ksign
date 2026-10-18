import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The optics shader consumes only two panes. Select them without allocating
/// and sorting a copy of every row's geometry during scrolling.
enum NBGlassPaneSelection {
    static func largest<S: Sequence>(_ rects: S) -> [CGRect] where S.Element == CGRect {
        var first: CGRect?
        var second: CGRect?
        for rect in rects {
            if let current = first {
                if precedes(rect, current) {
                    second = current
                    first = rect
                } else if let current = second {
                    if precedes(rect, current) { second = rect }
                } else {
                    second = rect
                }
            } else {
                first = rect
            }
        }
        guard let first else { return [] }
        if let second { return [first, second] }
        return [first]
    }

    private static func precedes(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let a = lhs.width * lhs.height
        let b = rhs.width * rhs.height
        if a != b { return a > b }
        if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
        return lhs.minX < rhs.minX
    }
}

import SwiftUI

/// Report the first layout as well as subsequent layouts. A one-shot task
/// keyed only by a refresh request can consume a provisional frame and never
/// deliver the settled frame. Keep this reporter mounted with its owner.
struct NBAuroraTextGeometryReport<Value: Equatable>: View {
    let value: Value
    let revision: UInt64
    let receive: (Value) -> Void

    var body: some View {
        Color.clear
            .onAppear { receive(value) }
            .onChange(of: value) { receive($0) }
            .onChange(of: revision) { _ in receive(value) }
    }
}

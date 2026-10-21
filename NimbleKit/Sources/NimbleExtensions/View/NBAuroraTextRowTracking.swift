import SwiftUI

/// A row's global frame includes its selection scale; local label coordinates
/// do not. Keep both sizes so the same affine mapping preserves ink alignment.
struct NBAuroraTextRowGeometry: Equatable {
    let frame: CGRect
    let size: CGSize

    func clipped(to viewport: NBAuroraTextViewport?) -> Self {
        guard let viewport, let window = viewport.window else { return self }
        guard NBAuroraTextVisibility.intersects(frame, window: window, clipping: viewport.clipping) else {
            return Self(frame: .null, size: .zero)
        }
        return self
    }

    func globalFrame(for local: CGRect) -> CGRect {
        guard !frame.isNull, !frame.isEmpty, size.width > 0, size.height > 0,
              !local.isNull, !local.isEmpty else { return .null }
        let sx = frame.width / size.width, sy = frame.height / size.height
        return CGRect(x: frame.minX + local.minX * sx, y: frame.minY + local.minY * sy,
                      width: local.width * sx, height: local.height * sy)
    }

    func inkBounds(for local: CGRect, window: CGRect) -> CGRect {
        let sx = frame.width / size.width, sy = frame.height / size.height
        return CGRect(x: (window.minX - frame.minX) / sx - local.minX,
                      y: (window.minY - frame.minY) / sy - local.minY,
                      width: window.width / sx, height: window.height / sy)
    }
}

@available(iOS 17.0, tvOS 17.0, *)
@MainActor
final class NBAuroraRowTextPlacement: ObservableObject {
    @Published private(set) var bounds = CGRect.zero

    func receive(_ bounds: CGRect) {
        if self.bounds != bounds { self.bounds = bounds }
    }
}

/// Owning this object does not subscribe a scope to scroll or ink updates.
@available(iOS 17.0, tvOS 17.0, *)
@MainActor
final class NBAuroraRowTextClient: ObservableObject {
    let placement = NBAuroraRowTextPlacement()
    let lease = NBAuroraInkLease()
    var localFrame = CGRect.null
    var visible = false
}

@available(iOS 17.0, tvOS 17.0, *)
@MainActor
final class NBAuroraTextRowTracker: ObservableObject {
    let coordinateSpaceID = UUID()
    private var geometry = NBAuroraTextRowGeometry(frame: .null, size: .zero)
    private var viewport: NBAuroraTextViewport?
    private var active = false
    private var reduceMotion = false

    private struct WeakClient { weak var value: NBAuroraRowTextClient? }
    private var clients: [ObjectIdentifier: WeakClient] = [:]

    func configure(viewport: NBAuroraTextViewport?, active: Bool,
                   reduceMotion: Bool, refresh: Bool = false) {
        self.viewport = viewport
        self.active = active
        self.reduceMotion = reduceMotion
        updateClients(refresh: refresh)
    }

    func move(to geometry: NBAuroraTextRowGeometry) {
        guard self.geometry != geometry else { return }
        self.geometry = geometry
        updateClients()
    }

    func measure(_ client: NBAuroraRowTextClient, localFrame: CGRect) {
        client.localFrame = localFrame
        update(client)
    }

    func setVisible(_ client: NBAuroraRowTextClient, _ visible: Bool) {
        client.visible = visible
        if visible {
            // Prune only when a label joins, not on every scroll tick.
            clients = clients.filter { $0.value.value != nil }
            clients[ObjectIdentifier(client)] = WeakClient(value: client)
        } else {
            clients.removeValue(forKey: ObjectIdentifier(client))
        }
        update(client)
    }

    private func updateClients(refresh: Bool = false) {
        for client in clients.values { if let client = client.value { update(client, refresh: refresh) } }
    }

    private func update(_ client: NBAuroraRowTextClient, refresh: Bool = false) {
        let frame = geometry.globalFrame(for: client.localFrame)
        let window = viewport?.window
        let visible = active && client.visible && window.map {
            NBAuroraTextVisibility.intersects(frame, window: $0, clipping: viewport?.clipping)
        } == true
        if visible, let window {
            client.placement.receive(geometry.inkBounds(for: client.localFrame, window: window))
        }
        let lease = client.lease
        guard lease.active != visible || lease.reduceMotion != reduceMotion || (refresh && visible) else { return }
        NBAuroraInkMap.shared.update(lease, active: visible, reduceMotion: reduceMotion)
    }
}

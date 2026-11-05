import UIKit

/// Numeric UI progress sleeps in the background; worker/system reporting does
/// not depend on the main run loop. Foreground entry flushes the newest value.
final class ForegroundValueDelivery<Value> {
    private let delivery: LatestValueDelivery<Value>
    private var observers: [NSObjectProtocol] = []

    init(receive: @escaping (Value) -> Void) {
        delivery = LatestValueDelivery(receive: receive)
        delivery.setActive(false)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let center = NotificationCenter.default
            for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                         UIApplication.didBecomeActiveNotification] {
                self.observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                    self?.delivery.setActive(event.name == UIApplication.didBecomeActiveNotification)
                })
            }
            self.delivery.setActive(UIApplication.shared.applicationState == .active)
        }
    }

    func submit(_ value: Value) { delivery.submit(value) }
    func cancel() { delivery.cancel() }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

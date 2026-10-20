import Foundation

// UIKit lifecycle double; the runner supplies the production presentation
// observer and progress mailbox. No background installation work is simulated.
final class UIApplication {
    static let shared = UIApplication()
    enum State { case active, background }
    var applicationState = State.background
    static let willResignActiveNotification = Notification.Name("inactive")
    static let didEnterBackgroundNotification = Notification.Name("background")
    static let didBecomeActiveNotification = Notification.Name("active")
}

@main struct InstallPresentationTests {
    static func main() async {
        let presentation = IDeviceInstallPresentation.shared
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        await MainActor.run {
            precondition(!presentation.isActive)
            let first = IDeviceInstallProgress(), second = IDeviceInstallProgress()
            var firstValues: [Double] = [], secondValues: [Double] = []
            let firstID = presentation.observe {
                if let value = first.drain().upload { firstValues.append(value) }
            }
            let secondID = presentation.observe {
                if let value = second.drain().upload { secondValues.append(value) }
            }
            for index in 1...10_000 {
                let value = Double(index) / 10_000
                precondition(!first.submit(upload: value, allowsDelivery: presentation.isActive))
                precondition(!second.submit(upload: value / 2, allowsDelivery: presentation.isActive))
            }
            let center = NotificationCenter.default
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            precondition(presentation.isActive && firstValues == [1] && secondValues == [0.5])
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            precondition(firstValues == [1] && secondValues == [0.5], "Duplicate activation must not redeliver")

            // A timer queued before deactivation can expire in the background.
            precondition(first.submit(upload: 0.25, allowsDelivery: presentation.isActive))
            center.post(name: UIApplication.willResignActiveNotification, object: nil)
            precondition(first.drain(scheduled: true, delivering: presentation.isActive).upload == nil)
            precondition(!first.submit(upload: 0.75, allowsDelivery: presentation.isActive))
            center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            precondition(firstValues == [1])
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            precondition(firstValues == [1, 0.75])

            presentation.remove(firstID)
            center.post(name: UIApplication.willResignActiveNotification, object: nil)
            precondition(!first.submit(upload: 0.9, allowsDelivery: presentation.isActive))
            precondition(!second.submit(upload: 0.8, allowsDelivery: presentation.isActive))
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            precondition(firstValues == [1, 0.75] && secondValues == [0.5, 0.8],
                         "Removed attempts must stop receiving foreground callbacks")
            presentation.remove(secondID)
        }
        print("Passed native presentation suspension, coalesced resume, duplicate lifecycle events and observer cleanup")
    }
}

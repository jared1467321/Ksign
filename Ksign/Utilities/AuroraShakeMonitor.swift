import CoreMotion
import NimbleExtensions
import SwiftUI

/// Watches at the app level so navigation, sheets, and keyboard focus don't
/// change whether a shake can shuffle the shared sky.
@MainActor
final class AuroraShakeMonitor: ObservableObject {
    private let motionManager = CMMotionManager()
    private var gravity: SIMD3<Double>?
    private var impulse: (acceleration: SIMD3<Double>, timestamp: TimeInterval)?
    private var cooldownUntil: TimeInterval = 0

    func setEnabled(_ enabled: Bool) {
        guard enabled, motionManager.isAccelerometerAvailable else {
            motionManager.stopAccelerometerUpdates()
            gravity = nil
            impulse = nil
            cooldownUntil = 0
            return
        }
        guard !motionManager.isAccelerometerActive else { return }

        motionManager.accelerometerUpdateInterval = 1.0 / 30.0
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let acceleration = SIMD3(data.acceleration.x, data.acceleration.y, data.acceleration.z)
            let timestamp = data.timestamp
            Task { @MainActor [weak self] in
                guard let self, self.motionManager.isAccelerometerActive else { return }
                self.process(acceleration, at: timestamp)
            }
        }
    }

    private func process(_ acceleration: SIMD3<Double>, at timestamp: TimeInterval) {
        guard let gravity else {
            self.gravity = acceleration
            return
        }

        // Remove gravity so a resting phone or a slow tilt can't shuffle.
        self.gravity = gravity * 0.8 + acceleration * 0.2
        let movement = acceleration - gravity
        let strengthSquared = movement.x * movement.x
            + movement.y * movement.y + movement.z * movement.z
        guard timestamp >= cooldownUntil, strengthSquared >= 1.25 * 1.25 else { return }

        if let impulse {
            let elapsed = timestamp - impulse.timestamp
            let dot = movement.x * impulse.acceleration.x
                + movement.y * impulse.acceleration.y + movement.z * impulse.acceleration.z
            // A quick reversal distinguishes a shake from a single bump.
            if elapsed >= 0.05, elapsed <= 0.45, dot < 0 {
                self.impulse = nil
                cooldownUntil = timestamp + 1.0
                NBAurora.randomize()
                return
            }
            if elapsed <= 0.45 { return }
        }
        impulse = (movement, timestamp)
    }

    deinit {
        motionManager.stopAccelerometerUpdates()
    }
}

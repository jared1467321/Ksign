import CoreMotion
import Foundation
import NimbleExtensions
import SwiftUI

/// Watches at the app level so navigation, sheets, and keyboard focus don't
/// change whether a shake can shuffle the shared sky.
@MainActor
final class AuroraShakeMonitor: ObservableObject {
    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Asign aurora shake detection"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private var generation: UInt64 = 0

    func setEnabled(_ enabled: Bool) {
        guard enabled, motionManager.isAccelerometerAvailable else {
            generation &+= 1
            motionManager.stopAccelerometerUpdates()
            motionQueue.cancelAllOperations()
            return
        }
        guard !motionManager.isAccelerometerActive else { return }

        generation &+= 1
        let generation = generation
        // Each capture owns its detector. Late readings from an old capture
        // cannot change the filter used after a disable/re-enable transition.
        let detector = AuroraShakeDetector()
        motionManager.accelerometerUpdateInterval = 1.0 / 30.0
        motionManager.startAccelerometerUpdates(to: motionQueue) { [weak self] data, _ in
            guard let data else { return }
            let acceleration = SIMD3(data.acceleration.x, data.acceleration.y, data.acceleration.z)
            let timestamp = data.timestamp
            guard detector.process(acceleration, at: timestamp) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation,
                      self.motionManager.isAccelerometerActive else { return }
                NBAurora.randomize()
            }
        }
    }

    deinit {
        motionManager.stopAccelerometerUpdates()
        motionQueue.cancelAllOperations()
    }
}

// Confined to one serial motion queue per capture. No UI or main-actor work is
// scheduled for ordinary readings; only a recognized shake crosses that boundary.
private final class AuroraShakeDetector: @unchecked Sendable {
    private var gravity: SIMD3<Double>?
    private var impulse: (acceleration: SIMD3<Double>, timestamp: TimeInterval)?
    private var cooldownUntil: TimeInterval = 0

    func process(_ acceleration: SIMD3<Double>, at timestamp: TimeInterval) -> Bool {
        guard let gravity else {
            self.gravity = acceleration
            return false
        }

        // Remove gravity so a resting phone or a slow tilt can't shuffle.
        self.gravity = gravity * 0.8 + acceleration * 0.2
        let movement = acceleration - gravity
        let strengthSquared = movement.x * movement.x
            + movement.y * movement.y + movement.z * movement.z
        guard timestamp >= cooldownUntil, strengthSquared >= 1.25 * 1.25 else { return false }

        if let impulse {
            let elapsed = timestamp - impulse.timestamp
            let dot = movement.x * impulse.acceleration.x
                + movement.y * impulse.acceleration.y + movement.z * impulse.acceleration.z
            // A quick reversal distinguishes a shake from a single bump.
            if elapsed >= 0.05, elapsed <= 0.45, dot < 0 {
                self.impulse = nil
                cooldownUntil = timestamp + 1.0
                return true
            }
            if elapsed <= 0.45 { return false }
        }
        impulse = (movement, timestamp)
        return false
    }
}

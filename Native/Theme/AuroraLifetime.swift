import Foundation
import CoreFoundation

// Only UIKit/Combine/ProcessInfo interfaces are doubled. The controller and
// weak display-link target below are copied verbatim by test_themes.py.
private protocol ObservableObject {}
@propertyWrapper private struct Published<Value> {
    var wrappedValue: Value
}
private struct CAFrameRateRange {
    let minimum: Float
    let maximum: Float
    let preferred: Float
}
@MainActor
private final class AuroraTestProcessInfo {
    enum ThermalState { case nominal, serious, critical }
    static let processInfo = AuroraTestProcessInfo()
    var thermalState: ThermalState = .nominal
    var isLowPowerModeEnabled = false
}
@MainActor
private final class CADisplayLink {
    // Model UIKit's run-loop retention, including its strong target reference.
    static var activeLinks: [CADisplayLink] = []
    private let target: AuroraDisplayLinkTarget
    var timestamp: CFTimeInterval = 0
    var preferredFrameRateRange = CAFrameRateRange(minimum: 0, maximum: 0, preferred: 0)
    var preferredFramesPerSecond = 0
    private(set) var invalidated = false

    init(target: AuroraDisplayLinkTarget, selector: String) { self.target = target }
    func add(to: RunLoop, forMode: RunLoop.Mode) { Self.activeLinks.append(self) }
    func invalidate() {
        invalidated = true
        Self.activeLinks.removeAll { $0 === self }
    }
    func tick(_ time: CFTimeInterval) {
        timestamp = time
        target.fire(self)
    }
}

// PRODUCTION_CONTROLLER

@main
private enum AuroraLifetimeTests {
    @MainActor
    static func main() {
        weak var retired: AuroraPerformanceController?
        do {
            let controller = AuroraPerformanceController()
            retired = controller
            controller.start()
            controller.start()
            assert(CADisplayLink.activeLinks.count == 1)
        }
        assert(retired == nil, "The display link must not retain a discarded backdrop controller")
        let orphan = CADisplayLink.activeLinks[0]
        orphan.tick(0)
        assert(orphan.invalidated && CADisplayLink.activeLinks.isEmpty,
               "A link whose owner disappeared must remove itself from the run loop")

        let controller = AuroraPerformanceController()
        controller.start()
        let link = CADisplayLink.activeLinks[0]
        assert(controller.renderScale == 0.50)
        assert(link.preferredFrameRateRange.preferred == 30)
        for frame in 0...240 { link.tick(Double(frame) / 30) }
        assert(controller.renderScale == 0.54, "Stable frames must retain the original quality ramp")
        for frame in 1...240 { link.tick(8 + Double(frame) / 15) }
        assert(controller.renderScale == 0.38, "Slow frames must retain the original quality floor")
        controller.stop()
        assert(link.invalidated && CADisplayLink.activeLinks.isEmpty)
        controller.start()
        assert(CADisplayLink.activeLinks.count == 1)
        controller.stop()

        AuroraTestProcessInfo.processInfo.isLowPowerModeEnabled = true
        let lowPower = AuroraPerformanceController()
        lowPower.start()
        assert(lowPower.renderScale == 0.46)
        lowPower.stop()
        AuroraTestProcessInfo.processInfo.thermalState = .serious
        let hot = AuroraPerformanceController()
        hot.start()
        assert(hot.renderScale == 0.42)
        hot.stop()
        assert(CADisplayLink.activeLinks.isEmpty)
        print("Aurora lifetime tests passed: weak ownership, orphan cleanup, stop/restart and unchanged adaptive quality.")
    }
}

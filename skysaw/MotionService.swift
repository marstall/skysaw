import Foundation
import CoreMotion
import Combine

final class MotionService: ObservableObject {
    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()

    @Published var acceleration: CMAcceleration = .init(x: 0, y: 0, z: 0)
    @Published var magnitude: Double = 0
    @Published var didStep: Bool = false

    private var lastMag: Double = 1.0
    private var lastCrossingTime: TimeInterval = 0
    private let stepMinInterval: TimeInterval = 0.3 // seconds
    private let stepThreshold: Double = 0.15 // g deviation from 1g

    var isRunning: Bool { motionManager.isAccelerometerActive }

    func start() {
        guard motionManager.isAccelerometerAvailable else { return }
        motionManager.accelerometerUpdateInterval = 1.0 / 60.0
        motionManager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            guard let self = self, let data = data else { return }
            let acc = data.acceleration
            let mag = sqrt(acc.x * acc.x + acc.y * acc.y + acc.z * acc.z)

            // Simple peak detection around 1g to infer steps
            let now = Date().timeIntervalSince1970
            let deltaFrom1g = mag - 1.0
            let prevDelta = lastMag - 1.0
            // detect upward zero-crossing over threshold with debounce
            if prevDelta < 0, deltaFrom1g >= stepThreshold, (now - lastCrossingTime) > stepMinInterval {
                lastCrossingTime = now
                DispatchQueue.main.async {
                    self.didStep = true
                }
            }
            lastMag = mag

            DispatchQueue.main.async {
                self.acceleration = acc
                self.magnitude = mag
                if self.didStep {
                    // leave true for one runloop tick
                    DispatchQueue.main.async { self.didStep = false }
                }
            }
        }
    }

    func stop() {
        motionManager.stopAccelerometerUpdates()
    }
}


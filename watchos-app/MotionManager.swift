import Foundation
import CoreMotion

class MotionManager {
    private let motionManager = CMMotionManager()

    // Drempelwaarden met hysterese tegen ruis
    private let startThresholdDegrees: Double = 60.0
    private let stopThresholdDegrees: Double = 35.0

    var onDrinkThresholdReached: (() -> Void)?
    var onArmLowered: (() -> Void)?

    func startMonitoring(isCurrentlyDrinking: @escaping () -> Bool) {
        guard motionManager.isDeviceMotionAvailable else {
            print("CoreMotion DeviceMotion is niet beschikbaar op dit apparaat.")
            return
        }

        // 50Hz bemonsteringsfrequentie (elke 0.02 seconden)
        motionManager.deviceMotionUpdateInterval = 1.0 / 50.0

        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self = self, let motion = motion, error == nil else { return }

            // Omrekenen van radialen naar graden voor zowel pitch als roll
            let pitchDegrees = abs(motion.attitude.pitch * 180.0 / .pi)
            let rollDegrees = abs(motion.attitude.roll * 180.0 / .pi)
            let activeAngle = max(pitchDegrees, rollDegrees)

            if !isCurrentlyDrinking() {
                if activeAngle >= self.startThresholdDegrees {
                    self.onDrinkThresholdReached?()
                }
            } else {
                if activeAngle <= self.stopThresholdDegrees {
                    self.onArmLowered?()
                }
            }
        }
    }

    func stopMonitoring() {
        motionManager.stopDeviceMotionUpdates()
    }
}
import Foundation
import CoreMotion

enum DetectionMode {
    case angleOnly
    case gForceOnly
    case combined
}

class MotionManager {
    private let motionManager = CMMotionManager()

    // INSTELLINGEN VOOR VANAVOND
    // Verander deze variabele om snel een andere methode te testen!
    var currentMode: DetectionMode = .angleOnly

    // 1. Hoek Drempelwaarden (Relatief)
    private let startThresholdOffset: Double = 15.0
    private let stopThresholdOffset: Double = 10.0

    // 2. G-Kracht Drempelwaarden (Schokken)
    // 1.0G is gewone zwaartekracht. We meten hier zónder zwaartekracht (schokken).
    private let liftGThreshold: Double = 0.5 // Een vlotte ruk omhoog
    private let klapGThreshold: Double = 1.2 // Een harde klap op tafel

    var currentPitch: Double = 0.0
    var currentGForce: Double = 0.0 // Toegevoegd voor de console log
    var baselineAngle: Double?

    var onDrinkThresholdReached: (() -> Void)?
    var onArmLowered: (() -> Void)?

    func setBaseline() {
        self.baselineAngle = self.currentPitch
        print("Baseline gezet op: \(String(format: "%.2f", currentPitch))° | Test-Modus: \(currentMode)")
    }

    func startMonitoring(isCurrentlyDrinking: @escaping () -> Bool) {
        guard motionManager.isDeviceMotionAvailable else { return }

        // 50Hz bemonsteringsfrequentie (elke 0.02s data)
        motionManager.deviceMotionUpdateInterval = 1.0 / 50.0

        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self = self, let motion = motion, error == nil else { return }

            // -- 1. Bereken Graden (Hoek) --
            let pitchDegrees = abs(motion.attitude.pitch * 180.0 / .pi)
            let rollDegrees = abs(motion.attitude.roll * 180.0 / .pi)
            let activeAngle = max(pitchDegrees, rollDegrees)
            self.currentPitch = activeAngle

            // -- 2. Bereken G-Kracht (Schok) --
            let accX = motion.userAcceleration.x
            let accY = motion.userAcceleration.y
            let accZ = motion.userAcceleration.z
            // Vector lengte berekent de totale 3D klap
            let totalG = sqrt(accX*accX + accY*accY + accZ*accZ)
            self.currentGForce = totalG

            guard let baseline = self.baselineAngle else { return }
            let isDrinking = isCurrentlyDrinking()

            // -- 3. BEPAAL START OF STOP OP BASIS VAN DE GEKOZEN MODUS --
            var isLiftOff = false
            var isKlap = false

            switch self.currentMode {
            case .angleOnly:
                isLiftOff = activeAngle >= (baseline + self.startThresholdOffset)
                isKlap = activeAngle <= (baseline + self.stopThresholdOffset)
                
            case .gForceOnly:
                isLiftOff = totalG > self.liftGThreshold
                isKlap = totalG > self.klapGThreshold
                
            case .combined:
                // Starten doen we als de hoek klopt, OF als er een flinke ruk is.
                isLiftOff = activeAngle >= (baseline + self.startThresholdOffset) || totalG > self.liftGThreshold
                // Stoppen is optimaal bij een klap op tafel, OF als je arm weer in rust-hoek is.
                isKlap = activeAngle <= (baseline + self.stopThresholdOffset) || totalG > self.klapGThreshold
            }

            // -- 4. VOER ACTIES UIT --
            if !isDrinking {
                if isLiftOff { self.onDrinkThresholdReached?() }
            } else {
                if isKlap { self.onArmLowered?() }
            }
        }
    }

    func stopMonitoring() {
        motionManager.stopDeviceMotionUpdates()
        self.baselineAngle = nil
    }
}

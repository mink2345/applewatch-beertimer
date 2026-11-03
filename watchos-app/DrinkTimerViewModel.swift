import Foundation
import Combine

enum DrinkState {
    case idle
    case waiting
    case drinking
    case finished
}

class DrinkTimerViewModel: ObservableObject {
    @Published var state: DrinkState = .idle
    @Published var sessionPin: String = "1234"
    @Published var playerName: String = "Speler_\(Int.random(in: 10...99))"
    @Published var elapsedSeconds: Double = 0.0
    @Published var syncStatus: String = ""

    private let motionManager = MotionManager()
    private var timer: Timer?
    private var startTime: Date?

    // Vervang dit door het lokale IP-adres van je Mac of je DigitalOcean domein
    private let serverBaseURL = "http://192.168.68.122/api/score"

    init() {
        setupMotionCallbacks()
    }

    private func setupMotionCallbacks() {
        motionManager.onDrinkThresholdReached = { [weak self] in
            self?.startDrinkingTimer()
        }

        motionManager.onArmLowered = { [weak self] in
            guard let self = self, let start = self.startTime else { return }
            // Minimale duur van 0.4s om valse triggers bij het optillen te negeren
            if Date().timeIntervalSince(start) >= 0.4 {
                self.finishDrinking()
            }
        }
    }

    func armSensors() {
        elapsedSeconds = 0.0
        syncStatus = ""
        state = .waiting

        motionManager.startMonitoring { [weak self] in
            return self?.state == .drinking
        }
    }

    private func startDrinkingTimer() {
        guard state == .waiting else { return }
        state = .drinking
        startTime = Date()

        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            self.elapsedSeconds = Date().timeIntervalSince(start)
        }
    }

    private func finishDrinking() {
        guard state == .drinking, let start = startTime else { return }

        timer?.invalidate()
        timer = nil
        motionManager.stopMonitoring()

        elapsedSeconds = Date().timeIntervalSince(start)
        state = .finished

        let durationMs = Int(elapsedSeconds * 1000)
        sendScoreToBackend(durationMs: durationMs)
    }

    func reset() {
        timer?.invalidate()
        motionManager.stopMonitoring()
        elapsedSeconds = 0.0
        syncStatus = ""
        state = .idle
    }

    private func sendScoreToBackend(durationMs: Int) {
        guard let url = URL(string: serverBaseURL) else { return }

        let payload: [String: Any] = [
            "pin": sessionPin,
            "player_name": playerName,
            "duration_ms": durationMs
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        syncStatus = "Verzenden..."

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.syncStatus = "Fout: \(error.localizedDescription)"
                    return
                }
                if let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 201 {
                    self?.syncStatus = "Staat op het bord!"
                } else {
                    self?.syncStatus = "Server fout"
                }
            }
        }.resume()
    }
}
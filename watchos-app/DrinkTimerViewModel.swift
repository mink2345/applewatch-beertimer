import Foundation
import Combine

enum DrinkState {
    case idle
    case waiting
    case drinking
    case finished
}

struct ScoreEntry: Codable, Hashable {
    let pin: String
    let player_name: String
    let duration_ms: Int
}

class DrinkTimerViewModel: ObservableObject {
    @Published var state: DrinkState = .idle
    @Published var sessionPin: String = ""
    @Published var playerName: String = "Speler_\(Int.random(in: 10...99))"
    @Published var elapsedSeconds: Double = 0.0
    @Published var syncStatus: String = ""
    @Published var leaderboard: [ScoreEntry] = []

    var isMultiplayer: Bool = false

    private let motionManager = MotionManager()
    private var timer: Timer?
    private var startTime: Date?
    private var webSocketTask: URLSessionWebSocketTask?

    // Pas dit IP adres aan naar de Mac waarop Docker draait
    private let serverIP = "192.168.68.122"

    init() {
        setupMotionCallbacks()
    }

    // MARK: - Netwerk & Sessie Logica
    func createNewSession(completion: @escaping (Bool) -> Void) {
        let url = URL(string: "http://\(serverIP):8080/api/session")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            if let data = data, let res = try? JSONDecoder().decode([String: String].self, from: data), let pin = res["pin"] {
                DispatchQueue.main.async {
                    self?.sessionPin = pin
                    self?.connectWebSocket()
                    completion(true)
                }
            } else {
                DispatchQueue.main.async { completion(false) }
            }
        }.resume()
    }

    func connectWebSocket() {
        guard !sessionPin.isEmpty else { return }
        let wsURL = URL(string: "ws://\(serverIP):8080/ws?pin=\(sessionPin)")!
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = URLSession.shared.webSocketTask(with: wsURL)
        webSocketTask?.resume()
        receiveLeaderboardUpdates()
    }

    private func receiveLeaderboardUpdates() {
        webSocketTask?.receive { [weak self] result in
            if case .success(let message) = result {
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8) { self?.decodeScores(data) }
                case .data(let data):
                    self?.decodeScores(data)
                @unknown default: break
                }
                self?.receiveLeaderboardUpdates()
            }
        }
    }

    private func decodeScores(_ data: Data) {
        if let scores = try? JSONDecoder().decode([ScoreEntry].self, from: data) {
            DispatchQueue.main.async { self.leaderboard = scores }
        }
    }

    // MARK: - Sensor & Timer Logica
    private func setupMotionCallbacks() {
        motionManager.onDrinkThresholdReached = { [weak self] in self?.startDrinkingTimer() }
        motionManager.onArmLowered = { [weak self] in
            guard let self = self, let start = self.startTime else { return }
            if Date().timeIntervalSince(start) >= 0.4 { self.finishDrinking() }
        }
    }

    func armSensors(multiplayer: Bool) {
        self.isMultiplayer = multiplayer
        elapsedSeconds = 0.0
        syncStatus = ""
        state = .waiting

        motionManager.startMonitoring { [weak self] in return self?.state == .drinking }
    }

    func startDrinkingTimer() {
        guard state == .waiting else { return }
        state = .drinking
        startTime = Date()

        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            self.elapsedSeconds = Date().timeIntervalSince(start)
        }
    }

    func finishDrinking() {
        guard state == .drinking, let start = startTime else { return }
        timer?.invalidate()
        timer = nil
        motionManager.stopMonitoring()

        elapsedSeconds = Date().timeIntervalSince(start)
        state = .finished

        if isMultiplayer {
            sendScoreToBackend(durationMs: Int(elapsedSeconds * 1000))
        }
    }

    func reset() {
        timer?.invalidate()
        motionManager.stopMonitoring()
        elapsedSeconds = 0.0
        syncStatus = ""
        state = .idle
    }

    private func sendScoreToBackend(durationMs: Int) {
        let url = URL(string: "http://\(serverIP):8080/api/score")!
        let payload: [String: Any] = ["pin": sessionPin, "player_name": playerName, "duration_ms": durationMs]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        syncStatus = "Verzenden..."
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                if error != nil {
                    self?.syncStatus = "Netwerkfout"
                } else if let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 201 {
                    self?.syncStatus = "Score opgeslagen!"
                }
            }
        }.resume()
    }
    func laadTestData(completion: @escaping (Bool) -> Void) {
        self.sessionPin = "8888"
        self.leaderboard = [
            ScoreEntry(pin: "8888", player_name: "Thomas", duration_ms: 3120),
            ScoreEntry(pin: "8888", player_name: "Mink", duration_ms: 3850),
            ScoreEntry(pin: "8888", player_name: "Shanna", duration_ms: 4100),
            ScoreEntry(pin: "8888", player_name: "Pascal", duration_ms: 4500),
            ScoreEntry(pin: "8888", player_name: "Stein", duration_ms: 5200)
        ]
        completion(true)
    }

}


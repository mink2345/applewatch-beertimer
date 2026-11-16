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

struct LocalScore: Codable, Identifiable, Hashable {
    var id = UUID()
    let playerName: String
    let durationMs: Int
    let date: Date
}

class DrinkTimerViewModel: ObservableObject {
    @Published var state: DrinkState = .idle
    @Published var sessionPin: String = ""
    @Published var playerName: String = "Speler_\(Int.random(in: 10...99))"
    @Published var elapsedSeconds: Double = 0.0
    @Published var syncStatus: String = ""
    @Published var leaderboard: [ScoreEntry] = []
    @Published var localHistory: [LocalScore] = []
    private let historyKey = "myDrinkHistory"

    var isMultiplayer: Bool = false

    private let motionManager = MotionManager()
    private var timer: Timer?
    private var debugTimer: Timer? // Toegevoegd voor de video log
    private var startTime: Date?
    private var webSocketTask: URLSessionWebSocketTask?

    // Pas dit IP adres aan naar de Mac waarop Docker draait
    private let serverIP = "localhost"

    init() {
        setupMotionCallbacks()
        loadLocalHistory()
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
            // Tijd teruggezet van 0.4 naar 0.1, omdat we nu veel zuiverder meten wanneer hij staat
            if Date().timeIntervalSince(start) >= 0.1 { self.finishDrinking() }
        }
    }

    func armSensors(multiplayer: Bool) {
        self.isMultiplayer = multiplayer
        elapsedSeconds = 0.0
        syncStatus = ""
        state = .waiting

        motionManager.startMonitoring { [weak self] in return self?.state == .drinking }
        
        // Wacht een halve seconde zodat je hand stil is, zet dan het nulpunt en start de log
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.motionManager.setBaseline()
            self?.startDebugLogger()
        }
    }

    // EXTRA FUNCTIE: De Logger voor in je terminal
        func startDebugLogger() {
            print("\n--- NULMETING GEDAAN, LOG START ---")
            let logStart = Date()
            
            debugTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self = self, self.state == .waiting || self.state == .drinking else { return }
                let msSindsStart = Int(Date().timeIntervalSince(logStart) * 1000)
                
                // Haal zowel hoek als G-kracht op
                let pitch = self.motionManager.currentPitch
                let gForce = self.motionManager.currentGForce
                
                print(String(format: "⏱ [%5d ms] | State: %@ | Pitch: %5.2f° | G-Kracht: %4.2f G",
                             msSindsStart,
                             self.state == .waiting ? "WAIT " : "DRINK",
                             pitch,
                             gForce))
            }
        }

    func startDrinkingTimer() {
        guard state == .waiting else { return }
        state = .drinking
        startTime = Date()
        
        print("🚀 LIFT-OFF DETECTEERD! Timer loopt...")

        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            self.elapsedSeconds = Date().timeIntervalSince(start)
        }
    }

    func finishDrinking() {
        guard state == .drinking, let start = startTime else { return }
        
        timer?.invalidate()
        timer = nil
        debugTimer?.invalidate() // Stop de log
        debugTimer = nil
        motionManager.stopMonitoring()

        elapsedSeconds = Date().timeIntervalSince(start)
        state = .finished

        let durationInMs = Int(elapsedSeconds * 1000)

        // 1. Sla altijd lokaal op het horloge op!
        saveLocalScore(durationMs: durationInMs)

        // 2. Stuur alléén naar de cloud als we in Multiplayer zitten
        if isMultiplayer {
            sendScoreToBackend(durationMs: durationInMs)
        }
        print("⏹ KLAP OP TAFEL - Eindtijd: \(durationInMs) ms")
    }

    func reset() {
        timer?.invalidate()
        debugTimer?.invalidate()
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
    
    func loadLocalHistory() {
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let saved = try? JSONDecoder().decode([LocalScore].self, from: data) {
            self.localHistory = saved
        }
    }

    func saveLocalScore(durationMs: Int) {
        let newScore = LocalScore(
            playerName: self.playerName.isEmpty ? "Gast" : self.playerName,
            durationMs: durationMs,
            date: Date()
        )
        // Voeg bovenaan toe zodat de nieuwste bovenaan staat
        localHistory.insert(newScore, at: 0)
        
        // Optioneel: bewaar maximaal de laatste 100 tijden om ruimte te besparen
        if localHistory.count > 100 { localHistory = Array(localHistory.prefix(100)) }
        
        if let encoded = try? JSONEncoder().encode(localHistory) {
            UserDefaults.standard.set(encoded, forKey: historyKey)
        }
    }
}

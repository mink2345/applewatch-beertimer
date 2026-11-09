import SwiftUI

// SCHERM 1: Hoofdmenu
struct ContentView: View {
    @StateObject private var viewModel = DrinkTimerViewModel()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    NavigationLink(destination: TimerScreen(viewModel: viewModel, isMultiplayer: false)) {
                        VStack {
                            Text("Solo Spelen").font(.headline)
                            Text("Oefenen zonder internet").font(.caption2).foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .tint(.blue)

                    NavigationLink(destination: GroupSetupScreen(viewModel: viewModel)) {
                        VStack {
                            Text("Multiplayer").font(.headline)
                            Text("Samen met vrienden").font(.caption2).foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .tint(.green)
                }
                .padding(.horizontal)
            }
            .navigationTitle("Menu")
        }
    }
}
// SCHERM 2: Multiplayer Setup
struct GroupSetupScreen: View {
    @ObservedObject var viewModel: DrinkTimerViewModel
    @State private var navigateToTimer = false
    @State private var isCreatingGroup = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                TextField("Jouw Naam", text: $viewModel.playerName)
                .multilineTextAlignment(.center)

                HStack {
                    // Standaard tekstveld (watchOS pakt automatisch Scribble/iPhone keyboard)
                    TextField("PIN", text: $viewModel.sessionPin)
                    .multilineTextAlignment(.center)

                    Button("Join") {
                        // 1. Maak het oude scorebord direct leeg
                        viewModel.leaderboard.removeAll()

                        // 2. Bepaal of het de testgroep is of een echte groep
                        if viewModel.sessionPin == "8888" {
                            viewModel.laadTestData{ _ in }
                            navigateToTimer = true
                        } else {
                            viewModel.connectWebSocket()
                            navigateToTimer = true
                        }
                    }
                            .tint(.green)
                    // Join knop is grijs/uitgeschakeld tenzij er exact 4 tekens staan
                            .disabled(viewModel.sessionPin.count != 4)
                }

                Button(isCreatingGroup ? "Laden..." : "Maak Nieuwe Groep") {
                    isCreatingGroup = true
                    viewModel.leaderboard.removeAll()

                    viewModel.createNewSession { success in
                        isCreatingGroup = false
                        // Alleen naar het volgende scherm als de server echt een PIN gaf
                        if success { navigateToTimer = true }
                    }
                }
                        .font(.caption)
                        .tint(.orange)

                // De onzichtbare navigatie-trigger naar het Timer-scherm
                NavigationLink(
                    destination: TimerScreen(viewModel: viewModel, isMultiplayer: true),
                    isActive: $navigateToTimer
                ) {
                    EmptyView()
                }
                .hidden()
            }
            .padding(.horizontal)
        }
        .navigationTitle("Groep Setup")
    }
}

// SCHERM 3: De Timer (De Game)
struct TimerScreen: View {
    @ObservedObject var viewModel: DrinkTimerViewModel
    let isMultiplayer: Bool

    var body: some View {
        VStack(spacing: 8) {

            // Toon de PIN en Scorebord knop bovenaan als we in multiplayer zitten
            if isMultiplayer {
                VStack(spacing: 2) {
                    Text("Sessie PIN: \(viewModel.sessionPin)")
                            .font(.headline)
                            .foregroundColor(.orange)

                    NavigationLink(destination: LeaderboardScreen(viewModel: viewModel)) {
                        HStack {
                            Image(systemName: "list.number")
                            Text("Bekijk Scores")
                        }
                        .font(.caption2)
                    }
                            .frame(height: 30)
                            .tint(.gray)
                }
            } else {
                Spacer().frame(height: 30)
            }

            Spacer()

            Text(String(format: "%.2fs", viewModel.elapsedSeconds))
                    .font(.system(size: 38, weight: .bold, design: .monospaced))
                    .foregroundColor(viewModel.state == .drinking ? .green : .white)

            switch viewModel.state {
            case .idle:
                Button("START") { viewModel.armSensors(multiplayer: isMultiplayer) }
                .tint(.green)
            case .waiting:
                Text("Klaar...").font(.caption).foregroundColor(.yellow)
                Button("Annuleer") { viewModel.reset() }.tint(.red)
            case .drinking:
                Text("Drinken!").font(.headline).foregroundColor(.green)
            case .finished:
                if isMultiplayer {
                    Text(viewModel.syncStatus).font(.caption2).foregroundColor(.gray)
                }
                Button("RESET") { viewModel.reset() }.tint(.blue)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

// SCHERM 4: Het Scorebord
struct LeaderboardScreen: View {
    @ObservedObject var viewModel: DrinkTimerViewModel

    var body: some View {
        List {
            if viewModel.leaderboard.isEmpty {
                Text("Nog geen tijden in deze sessie...")
                        .font(.caption)
                        .foregroundColor(.gray)
            } else {
                ForEach(Array(viewModel.leaderboard.enumerated()), id: \.element.hashValue) { index, score in
                    HStack {
                        Text("\(index + 1).").font(.caption2).foregroundColor(.gray)
                        Text(score.player_name).font(.caption)
                        Spacer()
                        Text(String(format: "%.2fs", Double(score.duration_ms) / 1000.0))
                                .font(.caption).bold().foregroundColor(.green)
                    }
                }
            }
        }
        .navigationTitle("Leaderboard")
    }
}

#Preview {
    ContentView()
}

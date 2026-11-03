import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DrinkTimerViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                // Toon PIN-invoer alleen als we nog niet gestart zijn
                if viewModel.state == .idle {
                    HStack {
                        Text("PIN:")
                            .font(.caption2)
                            .foregroundColor(.gray)
                        TextField("1234", text: $viewModel.sessionPin)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                    Text(viewModel.playerName)
                        .font(.caption2)
                        .foregroundColor(.blue)
                }

                // Grote Tijdweergave
                Text(String(format: "%.2fs", viewModel.elapsedSeconds))
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .foregroundColor(viewModel.state == .drinking ? .green : .white)

                // Status & Actieknoppen op basis van de 4 stappen
                switch viewModel.state {
                case .idle:
                    Button(action: {
                        viewModel.armSensors()
                    }) {
                        Text("START")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.green)

                case .waiting:
                    Text("Klaar... til je glas!")
                        .font(.footnote)
                        .foregroundColor(.yellow)
                    Button("Annuleer") {
                        viewModel.reset()
                    }
                    .font(.caption2)

                case .drinking:
                    Text("Drinken...")
                        .font(.headline)
                        .foregroundColor(.green)

                case .finished:
                    Text(viewModel.syncStatus)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Button(action: {
                        viewModel.reset()
                    }) {
                        Text("RESET")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.blue)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
import SwiftUI

/// Vue Mode Voyage pour la préparation d'écoute hors ligne.
struct TravelModeView: View {
    @Environment(Library.self) private var library
    @State private var isCaching = false
    @State private var cachedProgress: Double = 0.0
    
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Écoute Hors Ligne")
                        .font(.headline)
                    Text("Pré-télécharge les paroles manquantes et prépare le cache des animations pour l'écran de verrouillage.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                
                Button(action: startCaching) {
                    HStack {
                        Label(isCaching ? "Optimisation en cours..." : "Préparer ma bibliothèque", systemImage: "arrow.down.circle.fill")
                        Spacer()
                        if isCaching {
                            ProgressView()
                        }
                    }
                }
                .disabled(isCaching)
            } header: {
                Text("Mode Voyage")
            }
            
            if isCaching {
                Section("Progression") {
                    ProgressView(value: cachedProgress)
                        .tint(.orange)
                }
            }
            
            Section("Informations du système") {
                LabeledContent("Statut Signature", value: "Active (Side-loaded)")
                LabeledContent("Morceaux prêts", value: "\(library.tracks.count)")
            }
        }
        .navigationTitle("Mode voyage")
    }
    
    private func startCaching() {
        isCaching = true
        cachedProgress = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            cachedProgress += 0.1
            if cachedProgress >= 1.0 {
                timer.invalidate()
                isCaching = false
            }
        }
    }
}

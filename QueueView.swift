import SwiftUI

/// File d'attente : le morceau en cours, « À suivre » et la suite.
struct QueueView: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let id = player.currentID, let t = library.track(id) {
                    Section {
                        TrackRow(track: t, isCurrent: true)
                            .listRowBackground(Color.white.opacity(0.08))
                    } header: {
                        header("En lecture")
                    }
                }

                Section {
                    if player.upNext.isEmpty {
                        Text("Utilise « Lire ensuite » sur un morceau pour l’ajouter ici.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(Array(player.upNext.enumerated()), id: \.offset) { i, id in
                        if let t = library.track(id) {
                            TrackRow(track: t, isCurrent: false)
                                .contentShape(Rectangle())
                                .onTapGesture { player.playUpNext(at: i) }
                                .listRowBackground(Color.clear)
                        }
                    }
                    .onDelete { player.removeUpNext(at: $0) }
                    .onMove { player.moveUpNext(from: $0, to: $1) }
                } header: {
                    HStack {
                        header("À suivre")
                        Spacer()
                        if !player.upNext.isEmpty {
                            Button("Effacer") { player.clearUpNext() }
                                .font(.subheadline.weight(.semibold))
                                .textCase(nil)
                        }
                    }
                }

                if !player.upcomingInQueue.isEmpty {
                    Section {
                        ForEach(player.upcomingInQueue.prefix(200), id: \.self) { qi in
                            if let t = library.track(player.queue[qi]) {
                                TrackRow(track: t, isCurrent: false)
                                    .contentShape(Rectangle())
                                    .onTapGesture { player.jump(toQueueIndex: qi) }
                                    .listRowBackground(Color.clear)
                            }
                        }
                    } header: {
                        header(player.shuffle ? "Ensuite (aléatoire)" : "Ensuite")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle("File d’attente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationBackground(.ultraThinMaterial)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.headline).foregroundStyle(.white).textCase(nil)
    }
}

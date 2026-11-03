import SwiftUI

// MARK: - File d'attente dans le lecteur (« Suivant », comme Musique)

struct QueuePanel: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Suivant").font(.headline)
                Spacer()
                pill("shuffle", on: player.shuffle) { player.setShuffle(!player.shuffle) }
                pill(player.repeatMode == .one ? "repeat.1" : "repeat", on: player.repeatMode != .off) { player.cycleRepeat() }
            }
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !player.upNext.isEmpty {
                        HStack {
                            Text("À suivre").font(.subheadline.weight(.semibold)).foregroundColor(.white.opacity(0.6))
                            Spacer()
                            Button("Effacer") { player.clearUpNext() }
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.vertical, 6)
                        ForEach(Array(player.upNext.enumerated()), id: \.offset) { i, id in
                            if let t = library.track(id) { row(t) { player.playUpNext(at: i) } }
                        }
                    }
                    let upcoming = Array(player.upcomingInQueue.prefix(100))
                    ForEach(upcoming, id: \.self) { qi in
                        if player.queue.indices.contains(qi), let t = library.track(player.queue[qi]) {
                            row(t) { player.jump(toQueueIndex: qi) }
                        }
                    }
                    if player.upNext.isEmpty && upcoming.isEmpty {
                        Text("Aucun morceau à suivre.")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.55))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    }
                }
            }
        }
    }

    private func pill(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(on ? Color.black.opacity(0.75) : .white)
                .frame(width: 44, height: 30)
                .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.15)))
        }
        .haptic(.selection, trigger: on)
    }

    private func row(_ t: Track, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Artwork(track: t, cornerRadius: 4, pixels: 120).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.body).lineLimit(1)
                    Text(t.displayArtist).font(.subheadline).foregroundColor(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

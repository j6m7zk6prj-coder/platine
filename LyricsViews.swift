import SwiftUI

// MARK: - Paroles (comme Musique : la ligne chantée en blanc, la liste suit toute seule)

struct LyricsPanel: View {
    let track: Track
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: AppSettings
    @State private var lines: [LyricLine]?
    @State private var active = -1
    @State private var searching = false
    @State private var notFound = false

    var body: some View {
        Group {
            if let lines {
                synced(lines)
            } else if let raw = track.lyrics, !raw.isEmpty {
                ScrollView(showsIndicators: false) {
                    Text(LyricsParser.plainText(raw))
                        .font(.system(size: settings.lyricsSize.points * 0.8, weight: .bold))
                        .foregroundColor(.white.opacity(0.9))
                        .lineSpacing(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 24)
                }
                .mask(fade)
            } else if searching {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Recherche des paroles…").foregroundColor(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 14) {
                    Text(notFound ? "Aucune parole trouvée pour ce morceau." : "Pas de paroles pour ce morceau.")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                    Button { Task { await search() } } label: {
                        Text("Chercher les paroles")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .frame(height: 36)
                            .background(Capsule().fill(Color.white.opacity(0.2)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: track.id.uuidString + "\(track.lyrics?.count ?? 0)") {
            notFound = false
            active = -1
            lines = track.lyrics.flatMap { LyricsParser.isSynced($0) ? LyricsParser.parse($0) : nil }
            if track.lyrics == nil { await search() }
        }
    }

    private func synced(_ lines: [LyricLine]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Device.isSmallScreen ? 18 : 24) {
                    ForEach(lines) { line in
                        Text(line.isInterlude ? "•  •  •" : line.text)
                            .font(.system(size: settings.lyricsSize.points * (Device.isSmallScreen ? 0.8 : 0.9), weight: .bold))
                            .foregroundColor(.white.opacity(line.id == active ? 1 : 0.32))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(line.id)
                            .contentShape(Rectangle())
                            .onTapGesture { player.seek(to: line.time) }
                    }
                }
                .padding(.vertical, 120)
                .animation(.easeOut(duration: 0.3), value: active)
            }
            .mask(fade)
            .onChange(of: active) { a in
                guard a >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo(a, anchor: UnitPoint(x: 0, y: 0.32)) }
            }
        }
        // Suit la chanson cinq fois par seconde : léger pour l'iPhone 8.
        .task(id: lines) {
            while !Task.isCancelled {
                let now = player.liveTime + 0.3
                var a = -1
                for line in lines where line.time <= now { a = line.id }
                if a != active { active = a }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private var fade: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.08),
            .init(color: .black, location: 0.86),
            .init(color: .clear, location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }

    private func search() async {
        guard !searching else { return }
        let id = track.id
        searching = true
        let found = await LyricsService.search(title: track.title, artist: track.artist, duration: track.duration)
        searching = false
        if let found { library.setLyrics(id, found) } else { notFound = true }
    }
}

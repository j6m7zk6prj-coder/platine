import SwiftUI

/// Panneau des paroles de l'écran « En lecture ».
struct LyricsPane: View {
    let track: Track
    @Environment(Library.self) private var library
    @State private var lines: [LyricLine]?
    @State private var searching = false
    @State private var notFound = false

    var body: some View {
        Group {
            if let lines {
                SyncedLyricsView(lines: lines)
            } else if let lyrics = track.lyrics, !lyrics.isEmpty {
                staticLyrics(lyrics)
            } else if searching {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Recherche des paroles…")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }
        }
        .frame(maxHeight: .infinity)
        .task(id: track.id.uuidString + (track.lyrics ?? "")) {
            lines = track.lyrics.flatMap { LyricsParser.isSynced($0) ? LyricsParser.parse($0) : nil }
            if track.lyrics == nil && !notFound { await searchOnline() }
        }
        .onChange(of: track.id) { _, _ in notFound = false }
    }

    private func staticLyrics(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white.opacity(0.88))
                .lineSpacing(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 28)
                .textSelection(.enabled)
        }
        .scrollIndicators(.hidden)
        .mask(LyricsFade())
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Pas de paroles", systemImage: "quote.bubble")
        } description: {
            Text(notFound
                 ? "Aucune parole trouvée pour ce morceau. Tu peux importer un fichier .lrc ou les coller dans « Modifier les infos »."
                 : "Ce morceau n’a pas encore de paroles.")
        } actions: {
            Button {
                Task { await searchOnline() }
            } label: {
                Label("Chercher les paroles", systemImage: "magnifyingglass")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
    }

    private func searchOnline() async {
        guard !searching else { return }
        let id = track.id
        searching = true
        let found = await LyricsService.search(title: track.title, artist: track.artist, duration: track.duration)
        searching = false
        if let found {
            library.setLyrics(id, found)
        } else {
            notFound = true
        }
    }
}

/// Paroles synchronisées façon Musique : la ligne chantée est mise en avant, les autres s'estompent.
struct SyncedLyricsView: View {
    let lines: [LyricLine]
    @Environment(Player.self) private var player
    @State private var lastUserScroll = Date.distantPast

    var body: some View {
        // Petit temps d'avance pour que la ligne s'allume au moment où elle est chantée.
        let now = player.currentTime + 0.2
        let active = activeIndex(at: now)
        let userBrowsing = Date().timeIntervalSince(lastUserScroll) < 3

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    Color.clear.frame(height: 90)
                    ForEach(lines) { line in
                        let distance = active.map { line.id - $0 } ?? (line.id + 1)
                        LyricLineView(line: line,
                                      distance: distance,
                                      interludeProgress: interludeProgress(line, now: now),
                                      browsing: userBrowsing)
                            .id(line.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                player.seek(to: line.time)
                                if !player.isPlaying { player.resume() }
                                lastUserScroll = .distantPast
                            }
                    }
                    Color.clear.frame(height: 320)
                }
                .padding(.trailing, 12)
            }
            .scrollIndicators(.hidden)
            .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { _ in lastUserScroll = Date() })
            .onChange(of: active) { _, newValue in
                guard let newValue, Date().timeIntervalSince(lastUserScroll) > 3 else { return }
                withAnimation(.spring(response: 0.7, dampingFraction: 0.88)) {
                    proxy.scrollTo(newValue, anchor: UnitPoint(x: 0.5, y: 0.22))
                }
            }
            .onAppear {
                if let active { proxy.scrollTo(active, anchor: UnitPoint(x: 0.5, y: 0.22)) }
            }
        }
        .mask(LyricsFade())
    }

    private func activeIndex(at time: Double) -> Int? {
        var result: Int?
        for line in lines {
            if line.time <= time { result = line.id } else { break }
        }
        return result
    }

    /// Progression (0 à 1) d'une pause instrumentale en cours.
    private func interludeProgress(_ line: LyricLine, now: Double) -> Double? {
        guard line.isInterlude else { return nil }
        let end = line.id + 1 < lines.count ? lines[line.id + 1].time : max(player.duration, line.time + 1)
        guard now >= line.time, now < end, end - line.time >= 2.5 else { return nil }
        return (now - line.time) / (end - line.time)
    }
}

struct LyricLineView: View {
    let line: LyricLine
    /// 0 = ligne chantée, négatif = déjà passée, positif = à venir.
    let distance: Int
    let interludeProgress: Double?
    let browsing: Bool

    private var isActive: Bool { distance == 0 }

    var body: some View {
        Group {
            if line.isInterlude {
                if let p = interludeProgress {
                    InterludeDots(progress: p)
                        .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
                } else {
                    Color.clear.frame(height: 0)
                }
            } else {
                Text(line.text)
                    .font(.system(size: 31, weight: .bold))
                    .lineSpacing(4)
                    .foregroundStyle(.white.opacity(isActive ? 1 : (browsing ? 0.55 : 0.3)))
                    .shadow(color: .white.opacity(isActive ? 0.45 : 0), radius: isActive ? 14 : 0)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaleEffect(isActive ? 1 : 0.96, anchor: .leading)
                    .blur(radius: (isActive || browsing) ? 0 : min(Double(abs(distance)) * 0.7, 2.4))
            }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: isActive)
        .animation(.easeInOut(duration: 0.3), value: browsing)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: interludeProgress == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.isInterlude ? "Pause instrumentale" : line.text)
        .accessibilityAddTraits(isActive ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }
}

/// Les trois points qui se remplissent pendant une pause instrumentale.
struct InterludeDots: View {
    let progress: Double

    var body: some View {
        HStack(spacing: 11) {
            ForEach(0..<3, id: \.self) { i in
                let fill = min(1, max(0, progress * 3 - Double(i)))
                Circle()
                    .fill(.white.opacity(0.28 + 0.72 * fill))
                    .frame(width: 13, height: 13)
                    .scaleEffect(0.85 + 0.15 * fill)
            }
        }
        // Léger mouvement de respiration, comme dans Musique.
        .scaleEffect(1 + 0.05 * sin(progress * .pi * 10), anchor: .leading)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Fondu en haut et en bas de la zone des paroles.
struct LyricsFade: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.08),
            .init(color: .black, location: 0.86),
            .init(color: .clear, location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }
}

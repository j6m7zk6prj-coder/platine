import SwiftUI

/// Panneau des paroles de l'écran « En lecture ».
struct LyricsPane: View {
    let track: Track
    /// Appelé quand on fait défiler les paroles (pour réafficher les commandes).
    var onInteract: () -> Void = {}
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var lines: [LyricLine]?
    @State private var searching = false
    @State private var notFound = false

    var body: some View {
        Group {
            if let lines {
                SyncedLyricsView(lines: lines, onInteract: onInteract)
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
                .font(.system(size: settings.lyricsSize.points - 5, weight: .bold))
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

/// Paroles synchronisées façon Musique : la ligne chantée se remplit en continu (à chaque image),
/// et les lignes montent en vague (celles du dessous suivent avec un léger retard).
/// La liste n'est recalculée qu'au changement de ligne : seul le balayage de la ligne chantée bouge à 60/120 i/s.
struct SyncedLyricsView: View {
    let lines: [LyricLine]
    var onInteract: () -> Void = {}
    @Environment(Player.self) private var player
    @Environment(AppSettings.self) private var settings
    @State private var heights: [Int: CGFloat] = [:]
    @State private var active: Int?
    /// Décalage quand tu fais défiler toi-même les paroles.
    @State private var browse: CGFloat = 0
    @State private var dragging: CGFloat = 0
    @State private var isDragging = false
    @State private var browsing = false
    @State private var browseEnd: Task<Void, Never>?

    private let spacing: CGFloat = 30
    /// Petit temps d'avance pour que la ligne s'allume au moment où elle est chantée.
    static let lead = 0.2

    var body: some View {
        let fontSize = settings.lyricsSize.points
        let tops = lineTops(estimate: fontSize * 1.3)

        GeometryReader { geo in
            let anchor = geo.size.height * 0.2
            let base: CGFloat = anchor - (active.map { tops[$0] } ?? -40)
            ZStack(alignment: .topLeading) {
                ForEach(lines) { line in
                    let distance = active.map { line.id - $0 } ?? (line.id + 1)
                    let y = base + tops[line.id] + browse + dragging
                    // Hors de l'écran : rien n'est dessiné (plus fluide).
                    if y > -400 && y < geo.size.height + 300 {
                        LyricLineView(line: line,
                                      distance: distance,
                                      end: endTime(line),
                                      browsing: browsing,
                                      fontSize: fontSize,
                                      height: heights[line.id] ?? 0)
                            .frame(width: max(0, geo.size.width - 12), alignment: .leading)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                                if abs((heights[line.id] ?? 0) - h) > 0.5 { heights[line.id] = h }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                player.seek(to: line.time)
                                if !player.isPlaying { player.resume() }
                                endBrowsing(after: 0)
                                withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) {
                                    active = line.id
                                    browse = 0
                                }
                            }
                            .offset(y: y)
                            // La vague : chaque ligne part un peu après celle du dessus.
                            .animation(isDragging ? nil : .spring(response: 0.72, dampingFraction: 0.86).delay(stagger(distance)), value: y)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { g in
                        isDragging = true
                        dragging = g.translation.height
                        browseEnd?.cancel()
                        if !browsing { browsing = true }
                        onInteract()
                    }
                    .onEnded { g in
                        let total = tops.last ?? 0
                        let landed = browse + g.translation.height + (g.predictedEndTranslation.height - g.translation.height) * 0.6
                        isDragging = false
                        dragging = 0
                        withAnimation(.spring(response: 0.55, dampingFraction: 0.9)) {
                            browse = min(max(landed, -total), total)
                        }
                        endBrowsing(after: 3)
                    }
            )
        }
        .mask(LyricsFade())
        // Suit la chanson sans redessiner toute la liste : la ligne active n'est mise à jour qu'à son changement.
        .task(id: lines) {
            while !Task.isCancelled {
                let now = player.liveTime + Self.lead
                let a = activeIndex(at: now)
                if a != active { active = a }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    /// Après quelques secondes sans toucher, les paroles reviennent toutes seules sur la ligne chantée.
    private func endBrowsing(after seconds: Double) {
        browseEnd?.cancel()
        browseEnd = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.75, dampingFraction: 0.88)) {
                browsing = false
                browse = 0
            }
        }
    }

    private func lineTops(estimate: CGFloat) -> [CGFloat] {
        var result: [CGFloat] = []
        result.reserveCapacity(lines.count)
        var y: CGFloat = 0
        for line in lines {
            result.append(y)
            let h = heights[line.id] ?? (line.isInterlude ? 0 : estimate)
            y += h + (h > 0 ? spacing : 0)
        }
        return result
    }

    private func stagger(_ distance: Int) -> Double {
        distance <= 0 ? 0 : min(Double(distance) * 0.038, 0.28)
    }

    private func endTime(_ line: LyricLine) -> Double {
        line.id + 1 < lines.count ? lines[line.id + 1].time : max(player.duration, line.time + 4)
    }

    private func activeIndex(at time: Double) -> Int? {
        // Recherche dichotomique : les lignes sont triées par temps.
        var lo = 0, hi = lines.count - 1, result: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= time { result = lines[mid].id; lo = mid + 1 } else { hi = mid - 1 }
        }
        return result
    }
}

struct LyricLineView: View {
    let line: LyricLine
    /// 0 = ligne chantée, négatif = déjà passée, positif = à venir.
    let distance: Int
    /// Début de la ligne suivante.
    let end: Double
    let browsing: Bool
    var fontSize: CGFloat = 31
    /// Hauteur mesurée de la ligne (pour remplir rangée par rangée).
    var height: CGFloat = 0
    @Environment(Player.self) private var player

    private var isActive: Bool { distance == 0 }
    private var showsInterlude: Bool { line.isInterlude && isActive && end - line.time >= 2.5 }

    var body: some View {
        Group {
            if line.isInterlude {
                if showsInterlude {
                    TimelineView(.animation(paused: !player.isPlaying)) { _ in
                        let now = player.liveTime + SyncedLyricsView.lead
                        InterludeDots(progress: min(1, max(0, (now - line.time) / (end - line.time))))
                    }
                    .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
                } else {
                    Color.clear.frame(height: 0)
                }
            } else {
                text
                    .foregroundStyle(.white.opacity(isActive ? 0.38 : (browsing ? 0.55 : 0.3)))
                    .overlay(alignment: .topLeading) {
                        if isActive {
                            // Le blanc avance sur la ligne au fil du chant, rangée après rangée, à chaque image.
                            TimelineView(.animation(paused: !player.isPlaying)) { _ in
                                // Lecture de currentTime : à l'arrêt, un saut dans le morceau met aussi la ligne à jour.
                                let _ = player.currentTime
                                text
                                    .foregroundStyle(.white)
                                    .mask(alignment: .topLeading) { SweepMask(progress: fill(at: player.liveTime), rows: rows) }
                            }
                            .shadow(color: .white.opacity(0.35), radius: 3)
                            .transition(.opacity)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaleEffect(isActive ? 1 : 0.955, anchor: .leading)
                    .blur(radius: (isActive || browsing || abs(distance) > 5) ? 0 : min(Double(abs(distance)) * 0.6, 2))
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.84), value: isActive)
        .animation(.easeInOut(duration: 0.35), value: browsing)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: showsInterlude)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.isInterlude ? "Pause instrumentale" : line.text)
        .accessibilityAddTraits(isActive ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    /// Part de la ligne déjà chantée (0 à 1), avec un départ et une arrivée en douceur.
    private func fill(at time: Double) -> Double {
        // Le chant occupe rarement toute la durée jusqu'à la ligne suivante.
        let length = max(0.6, min(end - line.time, 8) * 0.9)
        let p = min(1, max(0, (time + SyncedLyricsView.lead - line.time) / length))
        return p * p * (3 - 2 * p) * 0.25 + p * 0.75
    }

    private var text: some View {
        Text(line.text)
            .font(.system(size: fontSize, weight: .bold))
            .lineSpacing(4)
    }

    /// Nombre de rangées de texte (une ligne longue passe sur plusieurs rangées).
    private var rows: Int {
        let rowHeight = fontSize * 1.2 + 4
        return max(1, Int(((height + 4) / rowHeight).rounded()))
    }
}

/// Masque qui découvre le texte de gauche à droite, une rangée après l'autre, avec un bord doux.
struct SweepMask: View {
    let progress: Double
    let rows: Int

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { r in
                let local = min(1, max(0, progress * Double(rows) - Double(r)))
                let soft = 0.07
                let edge = local * (1 + 2 * soft) - soft
                LinearGradient(stops: [
                    .init(color: .black, location: min(1, max(0, edge - soft))),
                    .init(color: .clear, location: min(1, max(0, edge + soft)))
                ], startPoint: .leading, endPoint: .trailing)
            }
        }
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

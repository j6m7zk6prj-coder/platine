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

/// Paroles synchronisées façon Musique : la ligne chantée se remplit au fil du chant,
/// et les lignes montent en vague (celles du dessous suivent avec un léger retard).
struct SyncedLyricsView: View {
    let lines: [LyricLine]
    var onInteract: () -> Void = {}
    @Environment(Player.self) private var player
    @Environment(AppSettings.self) private var settings
    @State private var heights: [Int: CGFloat] = [:]
    /// Décalage quand tu fais défiler toi-même les paroles.
    @State private var browse: CGFloat = 0
    @State private var dragging: CGFloat = 0
    @State private var isDragging = false
    @State private var lastUserScroll = Date.distantPast

    private let spacing: CGFloat = 30

    var body: some View {
        // Petit temps d'avance pour que la ligne s'allume au moment où elle est chantée.
        let now = player.currentTime + 0.2
        let active = activeIndex(at: now)
        let browsing = isDragging || Date().timeIntervalSince(lastUserScroll) < 3
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
                                      interludeProgress: interludeProgress(line, now: now),
                                      browsing: browsing,
                                      fontSize: fontSize,
                                      fill: fill(line, distance: distance, now: now),
                                      height: heights[line.id] ?? 0)
                            .frame(width: max(0, geo.size.width - 12), alignment: .leading)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                                if abs((heights[line.id] ?? 0) - h) > 0.5 { heights[line.id] = h }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                player.seek(to: line.time)
                                if !player.isPlaying { player.resume() }
                                lastUserScroll = .distantPast
                                withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) { browse = 0 }
                            }
                            .offset(y: y)
                            // La vague : chaque ligne part un peu après celle du dessus.
                            .animation(isDragging ? nil : .spring(response: 0.66, dampingFraction: 0.84).delay(stagger(distance)), value: y)
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
                        lastUserScroll = Date()
                        onInteract()
                    }
                    .onEnded { g in
                        let total = tops.last ?? 0
                        let landed = browse + g.translation.height + (g.predictedEndTranslation.height - g.translation.height) * 0.6
                        isDragging = false
                        dragging = 0
                        lastUserScroll = Date()
                        withAnimation(.spring(response: 0.55, dampingFraction: 0.9)) {
                            browse = min(max(landed, -total), total)
                        }
                    }
            )
        }
        .mask(LyricsFade())
        .onChange(of: active) { _, _ in
            // Après 3 secondes sans toucher, les paroles reviennent sur la ligne chantée.
            if !isDragging && Date().timeIntervalSince(lastUserScroll) > 3 && browse != 0 {
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
        distance <= 0 ? 0 : min(Double(distance) * 0.045, 0.32)
    }

    /// Remplissage de la ligne : 1 pour les lignes déjà chantées, progression pour la ligne en cours.
    private func fill(_ line: LyricLine, distance: Int, now: Double) -> Double {
        if distance < 0 { return 1 }
        if distance > 0 { return 0 }
        let end = line.id + 1 < lines.count ? lines[line.id + 1].time : max(player.duration, line.time + 4)
        // Le chant occupe rarement toute la durée jusqu'à la ligne suivante.
        let length = max(0.6, min(end - line.time, 8) * 0.9)
        return min(1, max(0, (now - line.time) / length))
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
    var fontSize: CGFloat = 31
    /// Part de la ligne déjà chantée (0 à 1).
    var fill: Double = 0
    /// Hauteur mesurée de la ligne (pour remplir rangée par rangée).
    var height: CGFloat = 0

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
                text
                    .foregroundStyle(.white.opacity(isActive ? 0.38 : (browsing ? 0.55 : 0.3)))
                    .overlay(alignment: .topLeading) {
                        if isActive {
                            // Le blanc avance sur la ligne au fil du chant, rangée après rangée.
                            text
                                .foregroundStyle(.white)
                                .shadow(color: .white.opacity(0.5), radius: 2.5)
                                .mask(alignment: .topLeading) { SweepMask(progress: fill, rows: rows) }
                                .animation(.linear(duration: 0.12), value: fill)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaleEffect(isActive ? 1 : 0.96, anchor: .leading)
                    .blur(radius: (isActive || browsing || abs(distance) > 6) ? 0 : min(Double(abs(distance)) * 0.7, 2.4))
            }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: isActive)
        .animation(.easeInOut(duration: 0.3), value: browsing)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: interludeProgress == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.isInterlude ? "Pause instrumentale" : line.text)
        .accessibilityAddTraits(isActive ? AccessibilityTraits.isSelected : AccessibilityTraits())
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

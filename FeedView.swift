import SwiftUI
import AVFoundation

// MARK: - Découvrir : un fil vertical à faire défiler, comme TikTok

/// Un extrait : un morceau, quelques lignes de ses paroles et l'endroit où l'extrait commence.
struct FeedItem: Identifiable, Equatable {
    let id = UUID()
    let trackID: UUID
    /// Lignes de paroles affichées (avec leur temps si les paroles sont synchronisées).
    let lines: [LyricLine]
    let start: Double
    let synced: Bool

    static func == (a: FeedItem, b: FeedItem) -> Bool { a.id == b.id }
}

/// Lecteur d'extraits, séparé du lecteur principal : ta file d'attente n'est jamais touchée.
@MainActor
@Observable
final class FeedPreview {
    private let player = AVPlayer()
    private(set) var playing = false
    @ObservationIgnored private var loopObserver: Any?
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var current: UUID?
    /// Durée d'un extrait avant qu'il reprenne au début.
    static let length = 30.0

    var time: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? t : 0
    }

    func play(_ url: URL, from start: Double, item: UUID) {
        guard current != item else { if !playing { resume() }; return }
        current = item
        fadeTask?.cancel()
        if let loopObserver { player.removeTimeObserver(loopObserver) }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        let begin = CMTime(seconds: start, preferredTimescale: 600)
        player.seek(to: begin, toleranceBefore: .zero, toleranceAfter: .zero)
        // L'extrait tourne en boucle sur 30 secondes.
        let end = CMTime(seconds: start + Self.length, preferredTimescale: 600)
        loopObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: end)], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.player.seek(to: begin) }
        }
        fadeIn()
    }

    func resume() {
        guard player.currentItem != nil else { return }
        fadeIn()
    }

    func pause() {
        fadeTask?.cancel()
        player.pause()
        playing = false
    }

    func stop() {
        pause()
        current = nil
        player.replaceCurrentItem(with: nil)
    }

    /// Montée du son en douceur (pas de coupure brutale en changeant d'extrait).
    private func fadeIn() {
        player.volume = 0
        player.play()
        playing = true
        fadeTask = Task { [weak self] in
            for i in 1...12 {
                try? await Task.sleep(for: .milliseconds(30))
                guard let self, !Task.isCancelled else { return }
                self.player.volume = Float(i) / 12
            }
        }
    }
}

struct FeedView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(UIState.self) private var ui
    @State private var items: [FeedItem] = []
    @State private var position: UUID?
    @State private var preview = FeedPreview()
    @State private var muted = false
    @State private var lyricsOnly = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if library.tracks.isEmpty {
                ContentUnavailableView("Rien à découvrir", systemImage: "sparkles",
                                       description: Text("Importe de la musique : ses extraits apparaîtront ici."))
                    .foregroundStyle(.white)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            if let t = library.track(item.trackID) {
                                FeedPage(item: item, track: t, active: item.id == position, preview: preview,
                                         onListen: { listen(item, t) })
                                    .containerRelativeFrame([.horizontal, .vertical])
                                    .id(item.id)
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $position)
                .scrollIndicators(.hidden)
                .ignoresSafeArea()
            }

            // En haut : le titre et le filtre « avec paroles ».
            VStack {
                HStack {
                    Text("Découvrir").font(.title2.bold())
                    Spacer()
                    Button {
                        lyricsOnly.toggle()
                        rebuild()
                    } label: {
                        Label(lyricsOnly ? "Avec paroles" : "Tout", systemImage: lyricsOnly ? "quote.bubble.fill" : "quote.bubble")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .glassCapsule()
                    }
                    .buttonStyle(PressStyle(circle: false))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.top, 6)
                Spacer()
            }
        }
        .environment(\.colorScheme, .dark)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if items.isEmpty { rebuild() }
            // Le lecteur principal se met en pause : un seul son à la fois.
            if player.isPlaying { player.pause() }
            playCurrent()
        }
        .onDisappear { preview.pause() }
        .onChange(of: position) { _, _ in
            playCurrent()
            // Le fil ne finit jamais : de nouveaux extraits arrivent avant la fin.
            if let position, let i = items.firstIndex(where: { $0.id == position }), i >= items.count - 4 {
                items.append(contentsOf: batch())
            }
        }
        .onChange(of: player.isPlaying) { _, playing in
            if playing { preview.pause() }
        }
        .sensoryFeedback(.selection, trigger: position)
    }

    private func rebuild() {
        preview.stop()
        items = batch()
        position = items.first?.id
        playCurrent()
    }

    private func playCurrent() {
        guard let position, let item = items.first(where: { $0.id == position }),
              let t = library.track(item.trackID) else { return }
        preview.play(library.audioURL(t), from: item.start, item: item.id)
    }

    /// Écouter en entier : le morceau passe dans le lecteur principal, à l'endroit de l'extrait.
    private func listen(_ item: FeedItem, _ t: Track) {
        let at = preview.time
        preview.pause()
        let album = library.albumTrackIDs(of: t)
        let ids = library.tracks.filter { album.contains($0.id) }.map(\.id)
        player.play(ids: ids.isEmpty ? [t.id] : ids, startAt: t.id, shuffled: false)
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            player.seek(to: at)
        }
        ui.showPlayer = true
    }

    /// Une vingtaine d'extraits tirés au hasard (les titres avec paroles d'abord, sans doublon proche).
    private func batch() -> [FeedItem] {
        var pool = library.tracks
        if lyricsOnly { pool = pool.filter { ($0.lyrics ?? "").isEmpty == false } }
        if pool.isEmpty { pool = library.tracks }
        let recent = Set(items.suffix(8).map(\.trackID))
        var picked = pool.shuffled().filter { !recent.contains($0.id) }
        if picked.isEmpty { picked = pool.shuffled() }
        return picked.prefix(20).map(Self.excerpt)
    }

    /// Choisit quelques lignes de paroles au hasard et le moment où les jouer.
    static func excerpt(_ t: Track) -> FeedItem {
        let raw = t.lyrics ?? ""
        if LyricsParser.isSynced(raw), let lines = LyricsParser.parse(raw)?.filter({ !$0.isInterlude }), lines.count >= 2 {
            // Plutôt au milieu du morceau (le refrain y est souvent).
            let lo = lines.count / 5, hi = max(lo + 1, lines.count - 3)
            let i = Int.random(in: lo..<hi)
            let chunk = Array(lines[i..<min(lines.count, i + 3)])
            return FeedItem(trackID: t.id, lines: chunk, start: max(0, chunk[0].time - 1.5), synced: true)
        }
        let plain = LyricsParser.plainText(raw)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }
        let start = t.duration > 40 ? t.duration * Double.random(in: 0.28...0.5) : 0
        if plain.count >= 2 {
            let i = Int.random(in: 0..<(plain.count - 1))
            let chunk = plain[i..<min(plain.count, i + 3)].enumerated().map { LyricLine(id: $0.offset, time: 0, text: $0.element) }
            return FeedItem(trackID: t.id, lines: chunk, start: start, synced: false)
        }
        return FeedItem(trackID: t.id, lines: [], start: start, synced: false)
    }
}

/// Une page du fil : pochette en grand (animée si elle l'est), fond flou, paroles, et les boutons à droite.
private struct FeedPage: View {
    let item: FeedItem
    let track: Track
    let active: Bool
    let preview: FeedPreview
    var onListen: () -> Void
    @Environment(Library.self) private var library
    @Environment(UIState.self) private var ui
    @State private var liked = false
    @State private var burst = 0

    var body: some View {
        let colors = library.palette(for: track)
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                // Fond : la pochette floue et ses couleurs.
                ZStack {
                    LinearGradient(colors: [colors[0], colors[1], .black], startPoint: .top, endPoint: .bottom)
                    if let img = library.backdrop(for: track) {
                        Image(uiImage: img).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height).clipped()
                            .blur(radius: 30).opacity(0.7)
                    }
                    LinearGradient(colors: [.black.opacity(0.25), .clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                }
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: geo.safeAreaInsets.top + 60)
                    // La pochette, qui « respire » doucement pendant l'extrait.
                    ArtworkView(track: track, animated: active, cornerRadius: 16)
                        .frame(width: geo.size.width - 64, height: geo.size.width - 64)
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 18)
                        .scaleEffect(active && preview.playing ? 1 : 0.94)
                        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: active && preview.playing)
                        // Double toucher : aimer ; toucher : pause / lecture.
                        .onTapGesture(count: 2) { like() }
                        .onTapGesture { active && preview.playing ? preview.pause() : preview.resume() }
                        .overlay {
                            if !preview.playing && active {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 44))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .shadow(radius: 10)
                                    .transition(.scale.combined(with: .opacity))
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay {
                            HeartBurst(trigger: burst)
                        }
                    Spacer(minLength: 20)
                    FeedLyrics(item: item, active: active, preview: preview)
                        .padding(.horizontal, 24)
                        .padding(.trailing, 56)
                    Spacer(minLength: 16)
                    info
                        .padding(.horizontal, 20)
                        .padding(.bottom, geo.safeAreaInsets.bottom + 70)
                }

                // Boutons à droite, comme sur TikTok.
                VStack(spacing: 22) {
                    sideButton(liked ? "star.fill" : "star", liked ? "Favori" : "Aimer", tint: liked ? .yellow : .white) { like() }
                    sideButton("text.badge.plus", "Playlist") { ui.addToPlaylist = AddToPlaylistTarget(trackIDs: [track.id]) }
                    sideButton("play.circle.fill", "En entier", action: onListen)
                    ShareLink(item: library.audioURL(track)) {
                        VStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 24, weight: .semibold))
                            Text("Partager").font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 14)
                .padding(.bottom, geo.safeAreaInsets.bottom + 150)
            }
        }
        .onAppear { liked = track.isFavorite }
    }

    private var info: some View {
        HStack(spacing: 12) {
            ArtworkView(track: track, animated: false, small: true, cornerRadius: 8)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(track.title).font(.headline).lineLimit(1)
                    if track.explicit { ExplicitBadge(size: 13) }
                }
                Text(track.displayArtist).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            Spacer()
            if !track.album.isEmpty {
                NavigationLink { AlbumDetailView(albumID: track.albumKey) } label: {
                    Text("Album")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .glassCapsule()
                }
                .buttonStyle(PressStyle(circle: false))
            }
        }
        .foregroundStyle(.white)
        .overlay(alignment: .bottom) {
            // Avancée de l'extrait.
            TimelineView(.animation(paused: !active || !preview.playing)) { _ in
                let p = min(1, max(0, (preview.time - item.start) / FeedPreview.length))
                GeometryReader { g in
                    Capsule().fill(.white.opacity(0.2))
                        .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: g.size.width * (active ? p : 0)) }
                }
                .frame(height: 3)
            }
            .offset(y: 16)
        }
    }

    private func like() {
        if !liked { burst += 1 }
        liked.toggle()
        if liked != track.isFavorite { library.toggleFavorite(track.id) }
    }

    private func sideButton(_ symbol: String, _ title: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.4), radius: 4)
        }
        .buttonStyle(PressStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: liked)
    }
}

/// Les paroles de l'extrait : la ligne chantée s'allume si les paroles sont synchronisées.
private struct FeedLyrics: View {
    let item: FeedItem
    let active: Bool
    let preview: FeedPreview

    var body: some View {
        if item.lines.isEmpty {
            Text("♪").font(.system(size: 40, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !active || !item.synced || !preview.playing)) { _ in
                let now = preview.time
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(item.lines.enumerated()), id: \.offset) { i, line in
                        let next = i + 1 < item.lines.count ? item.lines[i + 1].time : line.time + 4
                        let on = !item.synced || (active && now >= line.time && now < next)
                        Text(line.text)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white.opacity(on ? 1 : 0.38))
                            .shadow(color: .black.opacity(0.35), radius: 6)
                            .lineLimit(3)
                            .animation(.easeOut(duration: 0.3), value: on)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .opacity(active ? 1 : 0.6)
            .animation(.easeOut(duration: 0.4), value: active)
        }
    }
}

/// Le cœur qui éclate au double toucher.
private struct HeartBurst: View {
    let trigger: Int
    @State private var shown = false

    var body: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 96))
            .foregroundStyle(.yellow)
            .shadow(color: .black.opacity(0.3), radius: 10)
            .scaleEffect(shown ? 1.1 : 0.4)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(false)
            .onChange(of: trigger) { _, _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { shown = true }
                Task {
                    try? await Task.sleep(for: .milliseconds(650))
                    withAnimation(.easeOut(duration: 0.3)) { shown = false }
                }
            }
    }
}

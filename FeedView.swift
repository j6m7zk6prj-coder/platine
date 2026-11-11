import SwiftUI
import AVFoundation
import ImageIO

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
            prefetch()
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

    /// Prépare les pochettes des pages suivantes avant qu'elles n'arrivent à l'écran.
    private func prefetch() {
        let start = position.flatMap { p in items.firstIndex { $0.id == p } } ?? 0
        let next = items.dropFirst(start + 1).prefix(3).compactMap { library.track($0.trackID) }
        Task {
            for t in next { _ = await FeedArtCache.shared.load(t, library: library) }
        }
    }

    private func rebuild() {
        preview.stop()
        items = batch()
        position = items.first?.id
        playCurrent()
        prefetch()
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

/// Les images de Découvrir, préparées hors du fil principal (et à l'avance pour les pages suivantes) :
/// le défilement ne décode jamais d'image ni de vidéo en plein glissement.
@MainActor
final class FeedArtCache {
    static let shared = FeedArtCache()

    struct Art {
        let image: UIImage
        let colors: [Color]
    }

    /// Le fichier à lire : toujours une image fixe (jamais l'animation, plus légère à faire défiler).
    struct Source: Sendable {
        let url: URL
        let kind: ArtworkKind
        var key: String { url.lastPathComponent }
    }

    private final class Box {
        let art: Art
        init(_ art: Art) { self.art = art }
    }

    private let cache = NSCache<NSString, Box>()
    private var loading: [String: Task<Art?, Never>] = [:]

    init() { cache.countLimit = 40 }

    static func source(_ t: Track, library: Library) -> Source? {
        let kind = library.artworkKind(t)
        if kind != .image, let e = t.embeddedArtwork {
            return Source(url: Library.artDir.appendingPathComponent(e), kind: .image)
        }
        guard let url = library.artworkURL(t) else { return nil }
        return Source(url: url, kind: kind)
    }

    func cached(_ t: Track, library: Library) -> Art? {
        guard let s = Self.source(t, library: library) else { return nil }
        return cache.object(forKey: s.key as NSString)?.art
    }

    func load(_ t: Track, library: Library) async -> Art? {
        guard let source = Self.source(t, library: library) else { return nil }
        let key = source.key
        if let hit = cache.object(forKey: key as NSString) { return hit.art }
        if let running = loading[key] { return await running.value }
        let task = Task<Art?, Never> {
            let image = await Task.detached(priority: .userInitiated) { FeedArtCache.decode(source) }.value
            guard let image else { return nil }
            let small = image.preparingThumbnail(of: CGSize(width: 64, height: 64)) ?? image
            let art = Art(image: image, colors: Palette.colors(from: small))
            self.cache.setObject(Box(art), forKey: key as NSString)
            return art
        }
        loading[key] = task
        let result = await task.value
        loading[key] = nil
        return result
    }

    /// Lit l'image en taille écran, déjà décodée.
    nonisolated static func decode(_ s: Source) -> UIImage? {
        let maxSide: CGFloat = 1100
        if s.kind == .video {
            let asset = AVURLAsset(url: s.url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxSide, height: maxSide)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            let total = asset.duration.seconds
            let at = total.isFinite && total > 0 ? total * 0.3 : 0.5
            guard let cg = try? gen.copyCGImage(at: CMTime(seconds: at, preferredTimescale: 600), actualTime: nil) else { return nil }
            return UIImage(cgImage: cg)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let src = CGImageSourceCreateWithURL(s.url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Une page du fil : la pochette en grand qui se fond dans ses couleurs,
/// et les paroles posées dessus dans une carte en verre liquide.
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
    @State private var art: FeedArtCache.Art?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let artHeight = min(geo.size.height * 0.68, w * 1.25)
            let colors = art?.colors ?? Palette.defaults
            ZStack(alignment: .top) {
                // Fond : les couleurs de la pochette, qui descendent vers le noir.
                LinearGradient(colors: [colors[0], colors[1].opacity(0.85), .black],
                               startPoint: .top, endPoint: .bottom)
                    .overlay(Color.black.opacity(0.25))

                // La pochette en grand : elle se fond dans le fond vers le bas.
                ZStack {
                    if let img = art?.image {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: w, height: artHeight)
                            .clipped()
                            .transition(.opacity)
                    }
                }
                .frame(width: w, height: artHeight)
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0),
                                           .init(color: .black, location: 0.5),
                                           .init(color: .black.opacity(0.55), location: 0.75),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .overlay(alignment: .top) {
                    // Assombrit le haut pour que le titre reste lisible.
                    LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: geo.safeAreaInsets.top + 110)
                }
                .overlay {
                    if !preview.playing && active {
                        Image(systemName: "play.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(26)
                            .glassCircle()
                            .transition(.scale.combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                }
                .overlay { HeartBurst(trigger: burst) }
                .contentShape(Rectangle())
                // Double toucher : aimer ; toucher : pause / lecture.
                .onTapGesture(count: 2) { like() }
                .onTapGesture { active && preview.playing ? preview.pause() : preview.resume() }
                .animation(.easeOut(duration: 0.25), value: art?.image)

                VStack(alignment: .leading, spacing: 14) {
                    Spacer(minLength: geo.safeAreaInsets.top + 60)
                    // Les paroles, dans une carte en verre posée sur le bas de la pochette.
                    FeedLyrics(item: item, active: active, preview: preview)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glass(28)
                    info
                    actions
                    progress
                }
                .padding(.horizontal, 16)
                .padding(.bottom, geo.safeAreaInsets.bottom + 66)
                .foregroundStyle(.white)
            }
            .frame(width: w, height: geo.size.height)
        }
        .onAppear {
            liked = track.isFavorite
            if art == nil { art = FeedArtCache.shared.cached(track, library: library) }
        }
        .task(id: track.id) {
            if art == nil { art = await FeedArtCache.shared.load(track, library: library) }
        }
    }

    private var info: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(track.title).font(.headline).lineLimit(1)
                    if track.explicit { ExplicitBadge(size: 13) }
                }
                Text(track.displayArtist).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            Spacer(minLength: 8)
            iconButton(liked ? "star.fill" : "star", label: liked ? "Retirer des favoris" : "Favori",
                       tint: liked ? .yellow : .white) { like() }
            iconButton("text.badge.plus", label: "Ajouter à une playlist") {
                ui.addToPlaylist = AddToPlaylistTarget(trackIDs: [track.id])
            }
            ShareLink(item: library.audioURL(track)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .glassCircle()
            }
            .accessibilityLabel("Partager")
        }
        .padding(.horizontal, 4)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: onListen) {
                Label("Écouter en entier", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .glassCapsule(interactive: true)
            }
            .buttonStyle(PressStyle(circle: false))
            if !track.album.isEmpty {
                NavigationLink { AlbumDetailView(albumID: track.albumKey) } label: {
                    Label("Album", systemImage: "square.stack")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .glassCapsule(interactive: true)
                }
                .buttonStyle(PressStyle(circle: false))
            }
            Spacer()
        }
    }

    /// Avancée de l'extrait (mise à jour quelques fois par seconde, seulement sur la page affichée).
    private var progress: some View {
        TimelineView(.animation(minimumInterval: 0.2, paused: !active || !preview.playing)) { _ in
            let p = active ? min(1, max(0, (preview.time - item.start) / FeedPreview.length)) : 0
            GeometryReader { g in
                Capsule().fill(.white.opacity(0.2))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white).frame(width: g.size.width * p)
                    }
            }
            .frame(height: 3)
            .animation(.linear(duration: 0.2), value: p)
        }
        .padding(.horizontal, 4)
    }

    private func like() {
        if !liked { burst += 1 }
        liked.toggle()
        if liked != track.isFavorite { library.toggleFavorite(track.id) }
    }

    private func iconButton(_ symbol: String, label: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 40)
                .glassCircle()
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
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
            Text("♪").font(.system(size: 34, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !active || !item.synced || !preview.playing)) { _ in
                let now = preview.time
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(item.lines.enumerated()), id: \.offset) { i, line in
                        let next = i + 1 < item.lines.count ? item.lines[i + 1].time : line.time + 4
                        let on = !item.synced || (active && now >= line.time && now < next)
                        Text(line.text)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white.opacity(on ? 1 : 0.4))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .animation(.easeOut(duration: 0.3), value: on)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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

import SwiftUI
import AVFoundation
import ImageIO
import CoreImage

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
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Tant que le morceau n'est pas calé au bon endroit, on annonce le début de l'extrait
    /// (les paroles ne montrent jamais le début du morceau par erreur).
    @ObservationIgnored private var pendingStart: Double?
    /// Durée d'un extrait avant qu'il reprenne au début.
    static let length = 30.0

    var time: Double {
        if let pendingStart { return pendingStart }
        let t = player.currentTime().seconds
        return t.isFinite ? t : 0
    }

    func play(_ url: URL, from start: Double, item: UUID) {
        guard current != item else { if !playing { resume() }; return }
        current = item
        fadeTask?.cancel()
        loadTask?.cancel()
        player.pause()
        playing = false
        if let loopObserver { player.removeTimeObserver(loopObserver) }
        loopObserver = nil
        pendingStart = start
        let playerItem = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: playerItem)
        let begin = CMTime(seconds: start, preferredTimescale: 600)
        loadTask = Task { [weak self] in
            // Le saut n'est fiable qu'une fois le fichier prêt : sinon l'extrait part du début du morceau.
            for _ in 0..<150 where playerItem.status == .unknown {
                try? await Task.sleep(for: .milliseconds(20))
                if Task.isCancelled { return }
            }
            guard let self, self.current == item, playerItem.status == .readyToPlay else { return }
            _ = await self.player.seek(to: begin, toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled, self.current == item else { return }
            self.pendingStart = nil
            // L'extrait tourne en boucle sur 30 secondes.
            let end = CMTime(seconds: start + Self.length, preferredTimescale: 600)
            self.loopObserver = self.player.addBoundaryTimeObserver(forTimes: [NSValue(time: end)], queue: .main) { [weak self] in
                MainActor.assumeIsolated {
                    self?.player.seek(to: begin, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
            self.fadeIn()
        }
    }

    func resume() {
        guard player.currentItem != nil, pendingStart == nil else { return }
        fadeIn()
    }

    func pause() {
        fadeTask?.cancel()
        player.pause()
        playing = false
    }

    func stop() {
        pause()
        loadTask?.cancel()
        pendingStart = nil
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
    /// Morceaux dont on a déjà cherché les paroles synchronisées (une seule fois chacun).
    @State private var searched: Set<UUID> = []

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
            findSyncedLyrics()
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

    /// Sans paroles synchronisées, on les cherche (LRCLIB) pour la page affichée :
    /// elles s'affichent dès qu'elles arrivent, calées sur le son.
    private func findSyncedLyrics() {
        guard let position, let item = items.first(where: { $0.id == position }),
              let t = library.track(item.trackID), !searched.contains(t.id),
              !LyricsParser.isSynced(t.lyrics ?? "") else { return }
        searched.insert(t.id)
        let id = t.id
        Task {
            guard let found = await LyricsService.search(title: t.title, artist: t.artist, duration: t.duration) else { return }
            if LyricsParser.isSynced(found) || library.track(id)?.lyrics == nil {
                library.setLyrics(id, found)
            }
        }
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
        findSyncedLyrics()
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
        if lyricsOnly { pool = pool.filter { LyricsParser.isSynced($0.lyrics ?? "") } }
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
        /// Version très floue (minuscule, agrandie à l'écran) : le fond sur lequel s'affichent les paroles.
        let blurred: UIImage
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
            let blurred = await Task.detached(priority: .userInitiated) { FeedArtCache.soften(small) }.value
            let art = Art(image: image, blurred: blurred ?? small, colors: Palette.colors(from: small))
            self.cache.setObject(Box(art), forKey: key as NSString)
            return art
        }
        loading[key] = task
        let result = await task.value
        loading[key] = nil
        return result
    }

    /// Un flou doux et lumineux à partir d'une toute petite image (rien n'est calculé pendant le défilement).
    nonisolated static func soften(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        let blurred = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35, kCIInputBrightnessKey: -0.06])
            .cropped(to: input.extent)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let out = ctx.createCGImage(blurred, from: input.extent) else { return nil }
        return UIImage(cgImage: out)
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

/// Une page du fil : la pochette en grand qui se fond dans sa propre version floue,
/// et les paroles qui s'allument par-dessus, calées sur le son.
private struct FeedPage: View {
    let item: FeedItem
    let track: Track
    let active: Bool
    let preview: FeedPreview
    var onListen: () -> Void
    @Environment(Library.self) private var library
    @Environment(UIState.self) private var ui
    @Environment(AppSettings.self) private var settings
    @State private var liked = false
    @State private var burst = 0
    @State private var art: FeedArtCache.Art?
    @State private var lines: [LyricLine] = []

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let artHeight = min(h * 0.62, w * 1.2)
            let colors = art?.colors ?? Palette.defaults
            ZStack(alignment: .top) {
                // Le fond : la pochette floue sur tout l'écran.
                ZStack {
                    LinearGradient(colors: [colors[0], colors[1], .black], startPoint: .top, endPoint: .bottom)
                    if let blurred = art?.blurred {
                        Image(uiImage: blurred)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .frame(width: w, height: h)
                            .clipped()
                            .transition(.opacity)
                    }
                    LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.35), .black.opacity(0.6)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .frame(width: w, height: h)

                // La pochette nette en haut, qui se fond dans le flou.
                ZStack {
                    if let img = art?.image {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: w, height: artHeight)
                            .clipped()
                            .transition(.opacity)
                    }
                    // La pochette animée, seulement sur la page affichée.
                    if active, settings.animatedArtwork, let moving = library.motion(track) {
                        Group {
                            if moving.kind == .gif {
                                AnimatedImageView(url: moving.url)
                            } else {
                                LoopingVideoView(url: moving.url, poster: art?.image)
                            }
                        }
                        .frame(width: w, height: artHeight)
                        .clipped()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
                .frame(width: w, height: artHeight)
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0),
                                           .init(color: .black, location: 0.45),
                                           .init(color: .black.opacity(0.5), location: 0.72),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .overlay(alignment: .top) {
                    LinearGradient(colors: [.black.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: geo.safeAreaInsets.top + 100)
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
                .animation(.easeOut(duration: 0.3), value: art?.image)
                .animation(.easeInOut(duration: 0.45), value: active)

                VStack(alignment: .leading, spacing: 16) {
                    Spacer(minLength: geo.safeAreaInsets.top + 60)
                    // Les paroles, posées directement sur le flou (sans cadre).
                    if !lines.isEmpty {
                        FeedLyrics(lines: lines, start: item.start, active: active, preview: preview)
                            .frame(height: min(250, h * 0.3), alignment: .top)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                    info
                    actions
                    progress
                }
                .padding(.horizontal, 20)
                .padding(.bottom, geo.safeAreaInsets.bottom + 66)
                .foregroundStyle(.white)
                .animation(.easeOut(duration: 0.4), value: lines.isEmpty)
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            // Double toucher : aimer ; toucher : pause / lecture.
            .onTapGesture(count: 2) { like() }
            .onTapGesture { active && preview.playing ? preview.pause() : preview.resume() }
        }
        .onAppear {
            liked = track.isFavorite
            if art == nil { art = FeedArtCache.shared.cached(track, library: library) }
        }
        .task(id: track.id) {
            if art == nil { art = await FeedArtCache.shared.load(track, library: library) }
        }
        .task(id: track.lyrics) {
            let raw = track.lyrics ?? ""
            let parsed = LyricsParser.isSynced(raw) ? (LyricsParser.parse(raw) ?? []).filter { !$0.isInterlude } : []
            if parsed != lines { lines = parsed }
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

    /// Avancée de l'extrait (seulement sur la page affichée).
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

/// Les paroles de Découvrir, comme dans Musique : la ligne chantée se remplit de blanc au fil du chant
/// et brille, les suivantes attendent en retrait, et tout monte en douceur au changement de ligne.
private struct FeedLyrics: View {
    let lines: [LyricLine]
    let start: Double
    let active: Bool
    let preview: FeedPreview
    @State private var current = 0
    @State private var heights: [Int: CGFloat] = [:]

    private let fontSize: CGFloat = 27
    /// Petite avance pour que la ligne s'allume au moment où elle est chantée.
    private let lead = 0.2

    var body: some View {
        let lo = max(0, current - 1)
        let hi = min(lines.count - 1, current + 3)
        VStack(alignment: .leading, spacing: 16) {
            if lo <= hi {
                ForEach(lo...hi, id: \.self) { i in
                    row(i)
                        .id(lines[i].id)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 24)),
                                                removal: .opacity.combined(with: .offset(y: -24))))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .black, location: 0.12),
                                   .init(color: .black, location: 0.82),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .onAppear { current = index(at: start + 1.6) }
        // Suit le son : on ne redessine qu'au changement de ligne.
        .task(id: active) {
            guard active else { return }
            while !Task.isCancelled {
                let i = index(at: preview.time + lead)
                if i != current {
                    withAnimation(.spring(response: 0.62, dampingFraction: 0.86)) { current = i }
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    @ViewBuilder private func row(_ i: Int) -> some View {
        let line = lines[i]
        let isActive = i == current && active
        let distance = i - current
        Text(line.text)
            .font(.system(size: fontSize, weight: .bold))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.white.opacity(isActive ? 0.32 : (distance < 0 ? 0.28 : 0.42)))
            .overlay(alignment: .topLeading) {
                if isActive {
                    // Le blanc avance sur la ligne, à chaque image, et la ligne brille.
                    TimelineView(.animation(paused: !preview.playing)) { _ in
                        Text(line.text)
                            .font(.system(size: fontSize, weight: .bold))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.white)
                            .mask(alignment: .topLeading) {
                                SweepMask(progress: fill(i, at: preview.time), rows: rows(line.id))
                            }
                    }
                    .shadow(color: .white.opacity(0.55), radius: 10)
                    .shadow(color: .white.opacity(0.35), radius: 3)
                    .transition(.opacity)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                if abs((heights[line.id] ?? 0) - h) > 0.5 { heights[line.id] = h }
            }
            .scaleEffect(isActive ? 1 : 0.96, anchor: .leading)
            .blur(radius: distance >= 2 ? 1.2 : 0)
            .animation(.spring(response: 0.55, dampingFraction: 0.84), value: isActive)
    }

    private func fill(_ i: Int, at time: Double) -> Double {
        let line = lines[i]
        let end = i + 1 < lines.count ? lines[i + 1].time : line.time + 4
        let length = max(0.6, min(end - line.time, 8) * 0.9)
        let p = min(1, max(0, (time + lead - line.time) / length))
        return p * p * (3 - 2 * p) * 0.25 + p * 0.75
    }

    private func rows(_ id: Int) -> Int {
        let rowHeight = fontSize * 1.2 + 3
        return max(1, Int((((heights[id] ?? rowHeight) + 3) / rowHeight).rounded()))
    }

    /// La ligne en cours à un instant donné (recherche dichotomique, les lignes sont dans l'ordre).
    private func index(at time: Double) -> Int {
        var lo = 0, hi = lines.count - 1, result = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= time { result = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return result
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

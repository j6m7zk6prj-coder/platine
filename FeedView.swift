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
/// Comme TikTok : la page suivante (et la précédente) sont déjà chargées et calées au bon endroit,
/// en silence ; en arrivant dessus, le son part tout de suite.
@MainActor
@Observable
final class FeedPreview {
    private(set) var playing = false
    @ObservationIgnored private var slots: [UUID: Slot] = [:]
    @ObservationIgnored private var current: UUID?
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    /// Durée d'un extrait avant qu'il reprenne au début.
    static let length = 30.0

    @MainActor
    final class Slot {
        let player = AVPlayer()
        let start: Double
        var ready = false
        var loop: Any?
        var task: Task<Void, Never>?
        init(start: Double) { self.start = start }
    }

    /// Où en est l'extrait affiché (le début de l'extrait tant qu'il n'est pas prêt).
    var time: Double {
        guard let current, let s = slots[current] else { return 0 }
        guard s.ready else { return s.start }
        let t = s.player.currentTime().seconds
        return t.isFinite ? t : s.start
    }

    /// Charge un extrait à l'avance, en silence, calé exactement à son début.
    func prepare(_ url: URL, from start: Double, item: UUID) {
        guard slots[item] == nil else { return }
        let slot = Slot(start: start)
        slots[item] = slot
        let p = slot.player
        p.automaticallyWaitsToMinimizeStalling = false
        p.volume = 0
        // Temps exact : sans ça, le saut au milieu d'un MP3 ou d'un FLAC tombe à côté (paroles décalées).
        let playerItem = AVPlayerItem(asset: AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]))
        p.replaceCurrentItem(with: playerItem)
        let begin = CMTime(seconds: start, preferredTimescale: 600)
        slot.task = Task { [weak self, weak slot] in
            for _ in 0..<250 where playerItem.status == .unknown {
                try? await Task.sleep(for: .milliseconds(20))
                if Task.isCancelled { return }
            }
            guard let slot, playerItem.status == .readyToPlay else { return }
            _ = await p.seek(to: begin, toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled else { return }
            // L'extrait tourne en boucle sur 30 secondes.
            let end = CMTime(seconds: start + Self.length, preferredTimescale: 600)
            slot.loop = p.addBoundaryTimeObserver(forTimes: [NSValue(time: end)], queue: .main) { [weak p] in
                MainActor.assumeIsolated { p?.seek(to: begin, toleranceBefore: .zero, toleranceAfter: .zero) }
            }
            p.preroll(atRate: 1) { _ in }
            slot.ready = true
            if self?.current == item { self?.startCurrent() }
        }
    }

    /// Joue l'extrait de la page affichée (tout de suite s'il est déjà prêt).
    func play(_ url: URL, from start: Double, item: UUID) {
        if current == item {
            if !playing { resume() }
            return
        }
        if let old = current, let s = slots[old] {
            s.player.pause()
            s.player.volume = 0
        }
        current = item
        playing = false
        prepare(url, from: start, item: item)
        if slots[item]?.ready == true { startCurrent() }
    }

    /// Garde seulement les extraits utiles (la page affichée et ses voisines).
    func keep(_ ids: Set<UUID>) {
        for (id, s) in slots where !ids.contains(id) && id != current {
            release(s)
            slots[id] = nil
        }
    }

    func resume() {
        guard current != nil else { return }
        startCurrent()
    }

    func pause() {
        fadeTask?.cancel()
        if let current { slots[current]?.player.pause() }
        playing = false
    }

    func stop() {
        pause()
        for s in slots.values { release(s) }
        slots = [:]
        current = nil
    }

    private func release(_ s: Slot) {
        s.task?.cancel()
        s.player.pause()
        if let loop = s.loop { s.player.removeTimeObserver(loop) }
        s.loop = nil
        s.player.replaceCurrentItem(with: nil)
    }

    private func startCurrent() {
        guard let current, let s = slots[current], s.ready else { return }
        let p = s.player
        p.volume = 0
        p.playImmediately(atRate: 1)
        playing = true
        // Montée du son très courte : le son part tout de suite, sans claquement.
        fadeTask?.cancel()
        fadeTask = Task { [weak p] in
            for i in 1...8 {
                try? await Task.sleep(for: .milliseconds(20))
                guard let p, !Task.isCancelled else { return }
                p.volume = Float(i) / 8
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
                                FeedPage(item: item, track: t, active: item.id == position, preview: preview)
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

            // Le menu se range en un petit bouton Accueil, comme dans Musique.
            VStack {
                Spacer()
                HStack {
                    Button {
                        preview.pause()
                        ui.selectedTab = 0
                    } label: {
                        Image(systemName: "house.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 54, height: 54)
                            // Verre non interactif : le verre « interactif » d'iOS gardait parfois le toucher pour lui.
                            .modifier(GlassStyle(shape: Circle(), interactive: false))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel("Accueil")
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
            }
        }
        .environment(\.colorScheme, .dark)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(true)
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
        guard let position, let i = items.firstIndex(where: { $0.id == position }),
              let t = library.track(items[i].trackID) else { return }
        preview.play(library.audioURL(t), from: items[i].start, item: items[i].id)
        // Les pages voisines sont prêtes avant qu'on y arrive.
        var keep: Set<UUID> = [items[i].id]
        for j in [i + 1, i - 1, i + 2] where items.indices.contains(j) {
            if let n = library.track(items[j].trackID) {
                preview.prepare(library.audioURL(n), from: items[j].start, item: items[j].id)
                keep.insert(items[j].id)
            }
        }
        preview.keep(keep)
    }

    /// Une vingtaine d'extraits tirés au hasard (les titres avec paroles d'abord, sans doublon proche).
    private func batch() -> [FeedItem] {
        var pool = library.tracks
        if lyricsOnly { pool = pool.filter { LyricsParser.isSynced($0.lyrics ?? "") } }
        if pool.isEmpty { pool = library.tracks }
        let recent = Set(items.suffix(8).map(\.trackID))
        var picked = pool.shuffled().filter { !recent.contains($0.id) }
        if picked.isEmpty { picked = pool.shuffled() }
        return Self.spread(Array(picked.prefix(20)), after: items.last.flatMap { library.track($0.trackID) })
            .map(Self.excerpt)
    }

    /// Vraiment au hasard : jamais deux fois de suite le même artiste ni le même album quand c'est possible.
    static func spread(_ list: [Track], after last: Track?) -> [Track] {
        var rest = list
        var out: [Track] = []
        var prev = last
        while !rest.isEmpty {
            let i = rest.firstIndex { t in
                guard let p = prev else { return true }
                return t.displayArtist.lowercased() != p.displayArtist.lowercased() && t.albumKey != p.albumKey
            } ?? rest.firstIndex { t in prev.map { t.albumKey != $0.albumKey } ?? true } ?? 0
            let t = rest.remove(at: i)
            out.append(t)
            prev = t
        }
        return out
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
            // Très petite et très floue : seulement des couleurs, jamais une deuxième pochette reconnaissable.
            let tiny = image.preparingThumbnail(of: CGSize(width: 24, height: 24)) ?? small
            let blurred = await Task.detached(priority: .userInitiated) { FeedArtCache.soften(tiny) }.value
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
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 5])
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
                .overlay { HeartBurst(trigger: burst) }
                .animation(.easeOut(duration: 0.3), value: art?.image)
                .animation(.easeInOut(duration: 0.45), value: active)

                VStack(alignment: .leading, spacing: 16) {
                    Spacer(minLength: geo.safeAreaInsets.top + 60)
                    // Les paroles, posées directement sur le flou (sans cadre).
                    if !lines.isEmpty {
                        FeedLyrics(lines: lines, start: item.start, active: active, preview: preview)
                            .frame(height: min(300, h * 0.34), alignment: .top)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                    info
                    progress
                }
                .padding(.horizontal, 20)
                .padding(.bottom, geo.safeAreaInsets.bottom + 74)
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
            var parsed = LyricsParser.isSynced(raw) ? (LyricsParser.parse(raw) ?? []).filter { !$0.isInterlude } : []
            // Paroles d'une autre version (plus longues que le morceau) : forcément décalées, on ne les montre pas.
            if let last = parsed.last, track.duration > 0, last.time > track.duration + 3 { parsed = [] }
            if parsed != lines { lines = parsed }
        }
    }

    /// Le titre et l'artiste ; toucher ouvre l'album.
    private var info: some View {
        NavigationLink { AlbumDetailView(albumID: track.albumKey) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(track.title).font(.headline).lineLimit(1)
                    if track.explicit { ExplicitBadge(size: 13) }
                }
                Text(track.displayArtist).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .shadow(color: .black.opacity(0.35), radius: 6)
        }
        .buttonStyle(.plain)
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
        let hi = min(lines.count - 1, current + 2)
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
        // La lueur peut déborder sur les côtés…
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        // … et le haut et le bas s'effacent en douceur, comme dans le lecteur.
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .black, location: 0.16),
                                   .init(color: .black, location: 0.66),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .padding(.horizontal, -20)
        .padding(.vertical, -14)
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
            // De la place autour du texte : seules les lettres brillent, sans rectangle autour.
            .padding(GlowRoom.size)
            .blur(radius: distance >= 2 ? 1.2 : 0)
            .padding(-GlowRoom.size)
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

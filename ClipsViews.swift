import SwiftUI
import AVKit
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import ImageIO

// MARK: - Clips vidéo et edits (format TikTok)

/// Une vidéo importée : un clip (horizontal) ou un edit (vertical, format TikTok).
struct Clip: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var artist: String = ""
    var file: String
    var thumb: String?
    var duration: Double = 0
    var width: Double = 16
    var height: Double = 9
    var addedAt: Date = Date()
    var explicit: Bool = false
    /// Choix manuel : rangé dans les edits (true) ou dans les clips (false). Vide = selon le format.
    var forcedVertical: Bool?

    /// Plus haute que large : c'est un edit (format TikTok).
    var isVertical: Bool { forcedVertical ?? (height > width * 1.05) }
    var displayArtist: String { artist.isEmpty ? "Artiste inconnu" : artist }
}

/// Les clips et edits importés. Ils restent dans l'app (rien n'est modifié dans tes Photos).
@MainActor
@Observable
final class ClipStore {
    static let shared = ClipStore()

    private(set) var clips: [Clip] = []
    var importing = false

    static let dir = Library.base.appendingPathComponent("Clips", isDirectory: true)
    static let indexURL = Library.base.appendingPathComponent("clips.json")
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "3gp", "avi", "mkv"]

    @ObservationIgnored private let thumbs = NSCache<NSString, UIImage>()

    init() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.indexURL),
           let list = try? JSONDecoder().decode([Clip].self, from: data) {
            clips = list.filter { FileManager.default.fileExists(atPath: Self.dir.appendingPathComponent($0.file).path) }
            // Le format est relu sur la vignette (déjà tournée dans le bon sens) : un edit vertical
            // mal reconnu par une version précédente retourne dans les edits.
            var changed = false
            for i in clips.indices {
                guard let t = clips[i].thumb, let size = Self.imageSize(Self.dir.appendingPathComponent(t)) else { continue }
                if abs(clips[i].width - size.width) > 0.5 || abs(clips[i].height - size.height) > 0.5 {
                    clips[i].width = size.width
                    clips[i].height = size.height
                    changed = true
                }
            }
            if changed { save() }
        }
    }

    /// Clips horizontaux, du plus récent au plus ancien.
    var videos: [Clip] { clips.filter { !$0.isVertical }.sorted { $0.addedAt > $1.addedAt } }
    /// Edits verticaux, du plus récent au plus ancien.
    var edits: [Clip] { clips.filter { $0.isVertical }.sorted { $0.addedAt > $1.addedAt } }

    func clip(_ id: UUID) -> Clip? { clips.first { $0.id == id } }

    /// Taille d'une image sans la charger en entier.
    static func imageSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double, w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Ranger à la main dans les edits ou dans les clips.
    func setVertical(_ id: UUID, _ vertical: Bool) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[i].forcedVertical = vertical
        save()
    }
    func url(_ c: Clip) -> URL { Self.dir.appendingPathComponent(c.file) }

    func thumbnail(_ c: Clip) -> UIImage? {
        guard let name = c.thumb else { return nil }
        if let img = thumbs.object(forKey: name as NSString) { return img }
        guard let img = UIImage(contentsOfFile: Self.dir.appendingPathComponent(name).path) else { return nil }
        thumbs.setObject(img, forKey: name as NSString)
        return img
    }

    /// Copie la vidéo dans l'app, lit sa taille et sa durée, et prépare une vignette.
    @discardableResult
    func importVideo(at source: URL, title: String? = nil, vertical: Bool? = nil) async -> UUID? {
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
        let id = UUID()
        let name = id.uuidString + "." + ext
        let dest = Self.dir.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            return nil
        }
        let asset = AVURLAsset(url: dest)
        var duration = 0.0
        var size = CGSize(width: 16, height: 9)
        if let d = try? await asset.load(.duration) { duration = d.seconds.isFinite ? d.seconds : 0 }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let info = try? await track.load(.naturalSize, .preferredTransform) {
            let r = CGRect(origin: .zero, size: info.0).applying(info.1)
            size = CGSize(width: abs(r.width), height: abs(r.height))
        }
        var thumbName: String?
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 720)
        let at = CMTime(seconds: min(1.0, duration / 3), preferredTimescale: 600)
        if let cg = try? await gen.image(at: at).image,
           let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.82) {
            // L'image est déjà dans le bon sens : c'est la mesure la plus sûre du format.
            size = CGSize(width: cg.width, height: cg.height)
            let tn = id.uuidString + "-thumb.jpg"
            if (try? data.write(to: Self.dir.appendingPathComponent(tn), options: .atomic)) != nil { thumbName = tn }
        }
        let fallback = source.deletingPathExtension().lastPathComponent
        let defaultTitle = (fallback.count > 30 || fallback.hasPrefix("IMG_") || fallback.contains("-")) ? "Nouveau clip" : fallback
        let clip = Clip(id: id, title: title ?? defaultTitle, file: name, thumb: thumbName,
                        duration: duration, width: Double(size.width), height: Double(size.height),
                        forcedVertical: vertical)
        clips.append(clip)
        save()
        return id
    }

    /// Import depuis l'app Fichiers (plusieurs vidéos à la fois).
    func importFiles(_ urls: [URL], vertical: Bool? = nil) async -> UUID? {
        importing = true
        defer { importing = false }
        var last: UUID?
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let id = await importVideo(at: url, vertical: vertical) { last = id }
        }
        return last
    }

    /// Import depuis Photos.
    func importFromPhotos(_ items: [PhotosPickerItem], vertical: Bool? = nil) async -> UUID? {
        importing = true
        defer { importing = false }
        var last: UUID?
        for item in items {
            guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else { continue }
            if let id = await importVideo(at: movie.url, vertical: vertical) { last = id }
            try? FileManager.default.removeItem(at: movie.url)
        }
        return last
    }

    func update(_ id: UUID, title: String, artist: String, explicit: Bool) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let t = title.trimmingCharacters(in: .whitespaces)
        clips[i].title = t.isEmpty ? clips[i].title : t
        clips[i].artist = artist.trimmingCharacters(in: .whitespaces)
        clips[i].explicit = explicit
        save()
    }

    func remove(_ id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let c = clips.remove(at: i)
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(c.file))
        if let t = c.thumb { try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(t)) }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(clips) else { return }
        try? data.write(to: Self.indexURL, options: .atomic)
    }
}

// PickedMovie (vidéo choisie dans Photos) est déjà défini dans ArtworkEditor.swift.

// MARK: - Lecture

/// Un clip horizontal : le lecteur vidéo d'iOS en plein écran (rotation, AirPlay, image dans l'image).
@MainActor
enum ClipPlayback {
    static func play(_ clip: Clip, music: Player) {
        if music.isPlaying { music.pause() }
        let vc = AVPlayerViewController()
        vc.player = AVPlayer(url: ClipStore.shared.url(clip))
        vc.modalPresentationStyle = .fullScreen
        vc.allowsPictureInPicturePlayback = true
        top()?.present(vc, animated: true) { vc.player?.play() }
    }

    private static func top() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        var vc = window?.rootViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }
}

/// Vidéo avec le son, en boucle, qui ne joue que lorsqu'elle est à l'écran.
final class EditVideoUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var url: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(_ url: URL) {
        guard url != self.url else { return }
        self.url = url
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
    }

    func setPlaying(_ on: Bool) {
        if on { if player.timeControlStatus != .playing { player.play() } } else { player.pause() }
    }

    func stop() {
        player.pause()
        looper = nil
    }
}

struct EditVideoView: UIViewRepresentable {
    let url: URL
    let playing: Bool
    var fill = true

    func makeUIView(context: Context) -> EditVideoUIView {
        let v = EditVideoUIView()
        (v.layer as? AVPlayerLayer)?.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        v.load(url)
        v.setPlaying(playing)
        return v
    }

    func updateUIView(_ v: EditVideoUIView, context: Context) {
        v.load(url)
        (v.layer as? AVPlayerLayer)?.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        v.setPlaying(playing)
    }

    static func dismantleUIView(_ v: EditVideoUIView, coordinator: ()) { v.stop() }
}

/// Les edits en plein écran : on fait défiler vers le haut, comme sur TikTok.
struct EditsFeedView: View {
    let clips: [Clip]
    let startID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(Player.self) private var music
    @State private var position: UUID?
    @State private var paused = false

    init(clips: [Clip], startID: UUID) {
        self.clips = clips
        self.startID = startID
        _position = State(initialValue: startID)
    }
    @State private var editing: Clip?

    private var store: ClipStore { .shared }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(clips) { clip in
                        page(clip)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(clip.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $position)
            .scrollIndicators(.hidden)
            .ignoresSafeArea()

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Fermer")
                Spacer()
                Text("Edits").font(.headline)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 4)
            .padding(.horizontal, 10)
        }
        .statusBarHidden(false)
        .onAppear {
            if position == nil { position = startID }
            if music.isPlaying { music.pause() }
        }
        .onChange(of: position) { _, _ in paused = false }
        .sensoryFeedback(.selection, trigger: position)
        .sheet(item: $editing) { ClipInfoEditor(clip: $0) }
    }

    private func page(_ clip: Clip) -> some View {
        let active = clip.id == position
        return ZStack(alignment: .bottomLeading) {
            // Comme TikTok : la vidéo garde ses proportions (bandes noires si elle est plus large).
            EditVideoView(url: store.url(clip), playing: active && !paused, fill: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .contentShape(Rectangle())
                .onTapGesture { paused.toggle() }
                .overlay {
                    if paused && active {
                        Image(systemName: "play.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.white)
                            .frame(width: 88, height: 88)
                            .background(Circle().fill(.black.opacity(0.35)))
                            .allowsHitTesting(false)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: paused)

            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(clip.title).font(.headline).lineLimit(2)
                        if clip.explicit { ExplicitBadge(size: 14) }
                    }
                    Text(clip.displayArtist).font(.subheadline).opacity(0.8)
                }
                Spacer()
                VStack(spacing: 22) {
                    Button { editing = clip } label: {
                        sideIcon("pencil", "Infos")
                    }
                    ShareLink(item: store.url(clip)) { sideIcon("square.and.arrow.up", "Partager") }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.bottom, 50)
        }
    }

    private func sideIcon(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 24, weight: .semibold))
            Text(title).font(.caption2.weight(.semibold))
        }
        .shadow(color: .black.opacity(0.4), radius: 4)
    }
}

// MARK: - Vignettes

/// Vignette d'un clip : 16:9 pour un clip, 9:16 pour un edit, avec la durée en bas à droite.
struct ClipThumbnail: View {
    let clip: Clip
    var cornerRadius: CGFloat = 3

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Color(.secondarySystemFill)
            .overlay {
                if let img = ClipStore.shared.thumbnail(clip) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Image(systemName: "film").font(.title2).foregroundStyle(Color(.tertiaryLabel))
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color(.separator), lineWidth: 0.5))
            .overlay(alignment: .bottomTrailing) {
                Text(formatTime(clip.duration))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.6)))
                    .padding(5)
            }
    }
}

/// Carte d'un clip (horizontal) comme dans l'iTunes Store : vignette, titre et artiste.
struct ClipCard: View {
    let clip: Clip
    var width: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ClipThumbnail(clip: clip)
                .frame(width: width, height: width * 9 / 16)
            HStack(spacing: 5) {
                Text(clip.title).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                if clip.explicit { ExplicitBadge(size: 12) }
            }
            Text(clip.displayArtist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Carte d'un edit (vertical).
struct EditCard: View {
    let clip: Clip
    var width: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ClipThumbnail(clip: clip, cornerRadius: 6)
                .frame(width: width, height: width * 16 / 9)
            Text(clip.title).font(.footnote).foregroundStyle(.primary).lineLimit(1)
            Text(clip.displayArtist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Boutons d'import

/// « Importer » : depuis Photos ou depuis Fichiers.
/// Un clip importé ouvre sa fiche (titre, artiste) ; un edit est rangé directement, sans écran en plus.
struct ClipImportMenu<Content: View>: View {
    /// true : ranger dans les edits ; false : dans les clips ; vide : selon le format de la vidéo.
    var asEdit: Bool? = nil
    @ViewBuilder var label: () -> Content
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var naming: Clip?

    private var store: ClipStore { .shared }

    var body: some View {
        Menu {
            Button("Depuis Photos", systemImage: "photo.on.rectangle") { showPhotos = true }
            Button("Depuis Fichiers", systemImage: "folder") { showFiles = true }
        } label: {
            label()
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 20, matching: .videos)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                if let id = await store.importFiles(urls, vertical: asEdit), urls.count == 1,
                   let c = store.clip(id), !c.isVertical { naming = c }
            }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                let id = await store.importFromPhotos(items, vertical: asEdit)
                if let id, items.count == 1, let c = store.clip(id), !c.isVertical { naming = c }
                photoItems = []
            }
        }
        .sheet(item: $naming) { ClipInfoEditor(clip: $0) }
    }
}

/// Titre, artiste et « E » d'un clip.
struct ClipInfoEditor: View {
    let clip: Clip
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var explicit = false
    @State private var vertical = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ClipThumbnail(clip: clip, cornerRadius: 6)
                            .frame(width: clip.isVertical ? 110 : 240, height: clip.isVertical ? 196 : 135)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Titre", text: $title)
                    TextField("Artiste", text: $artist)
                    Toggle("Contenu explicite (E)", isOn: $explicit)
                }
                Section {
                    Picker("Ranger dans", selection: $vertical) {
                        Text("Clips vidéo").tag(false)
                        Text("Edits").tag(true)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Rubrique")
                } footer: {
                    Text("Les edits se regardent en plein écran en faisant défiler vers le haut, comme sur TikTok.")
                }
            }
            .navigationTitle("Infos du clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        ClipStore.shared.update(clip.id, title: title, artist: artist, explicit: explicit)
                        if vertical != clip.isVertical { ClipStore.shared.setVertical(clip.id, vertical) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                title = clip.title
                artist = clip.artist
                explicit = clip.explicit
                vertical = clip.isVertical
            }
        }
    }
}

// MARK: - Page « Clips vidéo »

/// Tous les clips et edits, avec un choix en segments comme dans l'iTunes Store.
struct ClipsView: View {
    var startOnEdits = false
    @Environment(Player.self) private var player
    @State private var segment = 0
    @State private var feedStart: Clip?
    @State private var editing: Clip?
    @State private var started = false

    private var store: ClipStore { .shared }

    var body: some View {
        let list = segment == 0 ? store.videos : store.edits
        ScrollView {
            Picker("Type", selection: $segment) {
                Text("Clips vidéo").tag(0)
                Text("Edits").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if store.importing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Import en cours…").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            if list.isEmpty {
                ContentUnavailableView {
                    Label(segment == 0 ? "Aucun clip" : "Aucun edit", systemImage: segment == 0 ? "film" : "rectangle.portrait.on.rectangle.portrait")
                } description: {
                    Text(segment == 0
                         ? "Importe tes clips depuis Photos ou Fichiers. Les vidéos horizontales arrivent ici."
                         : "Importe tes edits format TikTok. Les vidéos verticales arrivent ici et se regardent en faisant défiler.")
                } actions: {
                    ClipImportMenu(asEdit: segment == 1) { Text("Importer") }
                        .buttonStyle(OutlineButtonStyle())
                }
                .padding(.top, 40)
            } else if segment == 0 {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 18) {
                    ForEach(list) { clip in
                        GeometryReader { geo in
                            Button { ClipPlayback.play(clip, music: player) } label: {
                                ClipCard(clip: clip, width: geo.size.width)
                            }
                            .buttonStyle(PressStyle(circle: false))
                        }
                        .aspectRatio(16 / 13.5, contentMode: .fit)
                        .contextMenu { menu(clip) }
                    }
                }
                .padding(.horizontal, 16)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)], spacing: 3) {
                    ForEach(list) { clip in
                        Button { feedStart = clip } label: {
                            Color.clear
                                .aspectRatio(9 / 16, contentMode: .fit)
                                .overlay { ClipThumbnail(clip: clip, cornerRadius: 0) }
                                .clipped()
                        }
                        .buttonStyle(PressStyle(circle: false))
                        .contextMenu { menu(clip) }
                    }
                }
            }
        }
        .navigationTitle("Clips vidéo")
        .background { Color(.systemBackground).ignoresSafeArea() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ClipImportMenu(asEdit: segment == 1) { Image(systemName: "plus") }
                    .accessibilityLabel("Importer une vidéo")
            }
        }
        .onAppear {
            if !started { started = true; if startOnEdits { segment = 1 } }
        }
        .fullScreenCover(item: $feedStart) { clip in
            EditsFeedView(clips: store.edits, startID: clip.id)
        }
        .sheet(item: $editing) { ClipInfoEditor(clip: $0) }
    }

    @ViewBuilder private func menu(_ clip: Clip) -> some View {
        Button("Modifier les infos", systemImage: "pencil") { editing = clip }
        Button(clip.isVertical ? "Ranger dans les clips" : "Ranger dans les edits",
               systemImage: clip.isVertical ? "rectangle" : "rectangle.portrait") {
            store.setVertical(clip.id, !clip.isVertical)
        }
        ShareLink(item: store.url(clip)) { Label("Partager", systemImage: "square.and.arrow.up") }
        Button("Supprimer", systemImage: "trash", role: .destructive) { store.remove(clip.id) }
    }
}

// MARK: - Rubriques de l'Accueil

/// « Clips vidéo » et « Edits » sur l'Accueil, comme dans l'iTunes Store.
struct HomeClipSections: View {
    @Environment(Player.self) private var player
    @State private var feedStart: Clip?

    private var store: ClipStore { .shared }

    var body: some View {
        let videos = store.videos
        let edits = store.edits
        VStack(spacing: 0) {
            ClassicSeparator()
            HomeSection(title: "Clips vidéo", destination: { ClipsView() }) {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(videos.prefix(15)) { clip in
                            Button { ClipPlayback.play(clip, music: player) } label: { ClipCard(clip: clip) }
                                .buttonStyle(PressStyle(circle: false))
                                .contextMenu { moveMenu(clip) }
                        }
                        importCard(width: videos.isEmpty ? 240 : 150, height: 135,
                                   text: videos.isEmpty ? "Importer un clip" : "Importer", asEdit: false)
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 20)
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
            }

            ClassicSeparator()
            HomeSection(title: "Edits", destination: { ClipsView(startOnEdits: true) }) {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(edits.prefix(20)) { clip in
                            Button { feedStart = clip } label: { EditCard(clip: clip) }
                                .buttonStyle(PressStyle(circle: false))
                                .contextMenu { moveMenu(clip) }
                        }
                        importCard(width: 120, height: 213, text: edits.isEmpty ? "Importer un edit" : "Importer", asEdit: true)
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 20)
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
            }
        }
        .fullScreenCover(item: $feedStart) { clip in
            EditsFeedView(clips: edits, startID: clip.id)
        }
    }

    @ViewBuilder private func moveMenu(_ clip: Clip) -> some View {
        Button(clip.isVertical ? "Ranger dans les clips" : "Ranger dans les edits",
               systemImage: clip.isVertical ? "rectangle" : "rectangle.portrait") {
            store.setVertical(clip.id, !clip.isVertical)
        }
        Button("Supprimer", systemImage: "trash", role: .destructive) { store.remove(clip.id) }
    }

    private func importCard(width: CGFloat, height: CGFloat, text: String, asEdit: Bool) -> some View {
        ClipImportMenu(asEdit: asEdit) {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.title2.weight(.semibold))
                Text(text).font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
            }
            .foregroundStyle(.tint)
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.tint, style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])))
            .contentShape(Rectangle())
        }
    }
}

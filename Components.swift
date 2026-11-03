import SwiftUI
import AVKit
import MediaPlayer
import ImageIO

// MARK: - Couleurs (comme Musique sur iOS 16)

extension Color {
    /// Le rouge de Musique.
    static let music = Color(red: 0.98, green: 0.18, blue: 0.33)
}

// MARK: - Pochettes chargées en arrière-plan (fluide sur iPhone 8)

/// Les pochettes sont réduites à la taille affichée, hors du fil principal, et gardées en mémoire.
enum ArtworkLoader {
    static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 300
        return c
    }()

    static func cached(_ url: URL, pixels: Int) -> UIImage? {
        cache.object(forKey: "\(url.lastPathComponent)#\(pixels)" as NSString)
    }

    static func load(_ url: URL, pixels: Int) async -> UIImage? {
        let key = "\(url.lastPathComponent)#\(pixels)" as NSString
        if let img = cache.object(forKey: key) { return img }
        let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels
            ] as CFDictionary
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
            return UIImage(cgImage: cg)
        }.value
        if let img { cache.setObject(img, forKey: key) }
        return img
    }
}

/// Une pochette carrée, avec la note de musique grise quand il n'y en a pas (comme Musique).
struct Artwork: View {
    let track: Track?
    var cornerRadius: CGFloat = 6
    /// Taille de l'image chargée (en pixels).
    var pixels: Int = 300
    @EnvironmentObject private var library: Library
    @State private var image: UIImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let url = track.flatMap { library.stillURL($0) }
        Color(.systemGray5)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    GeometryReader { geo in
                        Image(systemName: "music.note")
                            .font(.system(size: geo.size.width * 0.4, weight: .medium))
                            .foregroundColor(Color(.systemGray2))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .task(id: (url?.lastPathComponent ?? "-") + "\(pixels)" + (track?.id.uuidString ?? "")) {
                if let url {
                    if let hit = ArtworkLoader.cached(url, pixels: pixels) { image = hit; return }
                    image = await ArtworkLoader.load(url, pixels: pixels)
                } else if let t = track, library.motion(t) != nil {
                    // Pochette seulement animée : on prend une image fixe (calculée une fois).
                    image = library.thumbnail(for: t)
                } else {
                    image = nil
                }
            }
    }
}

/// Le petit « E » des titres explicites.
struct ExplicitBadge: View {
    var size: CGFloat = 13

    var body: some View {
        Text("E")
            .font(.system(size: size * 0.72, weight: .bold))
            .foregroundColor(Color(.systemBackground))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 2.5).fill(Color.secondary))
            .accessibilityLabel("Explicite")
    }
}

// MARK: - Lignes et cellules

/// Une ligne de morceau, comme dans Musique : pochette (ou numéro), titre, artiste.
struct TrackRow: View {
    let track: Track
    var number: Int? = nil
    var showArtwork = true
    var subtitle: String? = nil
    @EnvironmentObject private var player: Player

    var body: some View {
        let current = player.currentID == track.id
        HStack(spacing: 12) {
            if let number {
                Group {
                    if current {
                        Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                            .font(.footnote)
                            .foregroundColor(.music)
                    } else {
                        Text("\(number)").font(.body).foregroundColor(.secondary).monospacedDigit()
                    }
                }
                .frame(width: 24)
            }
            if showArtwork {
                Artwork(track: track, cornerRadius: 4, pixels: 120)
                    .frame(width: 48, height: 48)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(track.title)
                        .font(.body)
                        .foregroundColor(current && number == nil ? .music : .primary)
                        .lineLimit(1)
                    if track.explicit { ExplicitBadge(size: 12) }
                }
                if let line = subtitle ?? (showArtwork ? track.displayArtist : nil) {
                    Text(line).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Menu {
                TrackMenu(track: track)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body)
                    .foregroundColor(.primary)
                    .frame(width: 32, height: 40)
                    .contentShape(Rectangle())
            }
        }
        .contentShape(Rectangle())
    }
}

/// Le menu d'un morceau (appui long ou « … »).
struct TrackMenu: View {
    let track: Track
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var ui: UIState

    var body: some View {
        Group {
            IconButton("Lire ensuite", systemImage: "text.insert") { player.playNext([track.id]) }
            IconButton("Lire plus tard", systemImage: "text.append") { player.playLater([track.id]) }
            IconButton("Ajouter à une playlist…", systemImage: "text.badge.plus") {
                ui.addToPlaylist = AddToPlaylistTarget(trackIDs: [track.id])
            }
            IconButton(track.isFavorite ? "Ne plus aimer" : "Aimer", systemImage: track.isFavorite ? "heart.slash" : "heart") {
                library.toggleFavorite(track.id)
            }
            IconButton("Modifier les infos", systemImage: "pencil") { ui.editingInfo = EditTarget(id: track.id) }
            Divider()
            IconButton("Supprimer de la bibliothèque", systemImage: "trash", role: .destructive) {
                library.remove([track.id])
                player.removed([track.id])
            }
        }
    }
}

/// « Lecture » et « Aléatoire » : deux boutons gris au texte rouge (page d'un album, d'une playlist).
struct PlayShuffleBar: View {
    let ids: [UUID]
    @EnvironmentObject private var player: Player

    var body: some View {
        HStack(spacing: 14) {
            button("Lecture", "play.fill") { player.play(ids: ids, shuffled: false) }
            button("Aléatoire", "shuffle") { player.play(ids: ids, shuffled: true) }
        }
        .disabled(ids.isEmpty)
    }

    private func button(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.body.weight(.semibold))
                .foregroundColor(.music)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemFill)))
        }
        .buttonStyle(.plain)
    }
}

/// Une case d'album dans une grille ou une rangée : pochette, titre, artiste.
struct AlbumCell: View {
    let album: AlbumInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Artwork(track: album.cover, cornerRadius: 6, pixels: 360)
                .padding(.bottom, 4)
            HStack(spacing: 4) {
                Text(album.title).font(.footnote.weight(.medium)).foregroundColor(.primary).lineLimit(1)
                if album.tracks.contains(where: \.explicit) { ExplicitBadge(size: 11) }
            }
            Text(album.artist).font(.footnote).foregroundColor(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

/// Pochette d'une playlist : les quatre premières pochettes, ou une note.
struct PlaylistArtwork: View {
    let playlist: Playlist
    var cornerRadius: CGFloat = 6
    @EnvironmentObject private var library: Library

    var body: some View {
        let covers = coverTracks
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if covers.count >= 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) { cell(covers[0]); cell(covers[1]) }
                    HStack(spacing: 0) { cell(covers[2]); cell(covers[3]) }
                }
            } else if let first = covers.first {
                Artwork(track: first, cornerRadius: 0, pixels: 360)
            } else {
                LinearGradient(colors: [Color(.systemGray3), Color(.systemGray5)], startPoint: .top, endPoint: .bottom)
                    .overlay(Image(systemName: "music.note.list").font(.title).foregroundColor(.white.opacity(0.8)))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(shape)
    }

    private func cell(_ t: Track) -> some View {
        Artwork(track: t, cornerRadius: 0, pixels: 180)
    }

    private var coverTracks: [Track] {
        var seen = Set<String>()
        var out: [Track] = []
        for t in library.tracks(playlist.trackIDs) where seen.insert(t.albumKey).inserted {
            out.append(t)
            if out.count == 4 { break }
        }
        return out
    }
}

/// Titre de section avec « Tout afficher » à droite, comme dans Musique.
struct SectionHeader<Destination: View>: View {
    let title: String
    let destination: (() -> Destination)?

    init(title: String, destination: (() -> Destination)?) {
        self.title = title
        self.destination = destination
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.bold())
            Spacer()
            if let destination {
                NavigationLink {
                    destination()
                } label: {
                    Text("Tout afficher").font(.body).foregroundColor(.music)
                }
            }
        }
        .padding(.horizontal, 20)
    }
}

extension SectionHeader where Destination == EmptyView {
    init(title: String) {
        self.title = title
        self.destination = nil
    }
}

// MARK: - Volume et AirPlay (réglages système, très légers)

/// La barre de volume de l'iPhone (MPVolumeView), aux couleurs du lecteur.
struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: .zero)
        v.showsVolumeSlider = true
        if let slider = v.subviews.compactMap({ $0 as? UISlider }).first {
            slider.minimumTrackTintColor = UIColor.white.withAlphaComponent(0.85)
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
        }
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 14, height: 14)).image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 14, height: 14))
        }
        v.setVolumeThumbImage(thumb, for: .normal)
        return v
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor.white.withAlphaComponent(0.7)
        v.activeTintColor = .white
        v.prioritizesVideoDevices = false
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

import SwiftUI
import ImageIO

/// Une pochette de la bibliothèque (fichier d'origine, en pleine résolution).
struct GalleryItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let kind: ArtworkKind
    let title: String
    let subtitle: String
    /// Morceau « porteur » de cette pochette (pour l'afficher avec ArtworkView).
    let track: Track
}

/// Toutes les pochettes en pleine résolution : à regarder, et à enregistrer si tu veux.
struct ArtworkGalleryView: View {
    @Environment(Library.self) private var library
    @State private var filter = 0
    @State private var selected: GalleryItem?

    private let columns = [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)]

    var body: some View {
        let all = Self.items(library)
        let shown = filter == 1 ? all.filter { $0.kind != .image } : all
        ScrollView {
            Picker("Filtre", selection: $filter) {
                Text("Toutes").tag(0)
                Text("Animées").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(shown) { item in
                    Button { selected = item } label: {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                if let img = library.thumbnail(for: item.track) {
                                    Image(uiImage: img).resizable().scaledToFill()
                                } else {
                                    Color(white: 0.15)
                                }
                            }
                            .clipped()
                            .overlay(alignment: .topLeading) {
                                if item.kind != .image {
                                    Label("ANIMÉE", systemImage: "play.fill")
                                        .font(.system(size: 9, weight: .heavy))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(.black.opacity(0.5)))
                                        .foregroundStyle(.white)
                                        .padding(5)
                                }
                            }
                    }
                    .buttonStyle(PressStyle(circle: false))
                }
            }
            .padding(.horizontal, 3)

            if shown.isEmpty {
                ContentUnavailableView("Aucune pochette", systemImage: "photo.on.rectangle",
                                       description: Text(filter == 1 ? "Aucune pochette animée pour l’instant." : "Importe de la musique pour voir ses pochettes."))
                    .padding(.top, 60)
            }
        }
        .navigationTitle("Pochettes")
        .navigationBarTitleDisplayMode(.large)
        .fullScreenCover(item: $selected) { item in
            ArtworkViewer(item: item)
        }
    }

    /// Toutes les pochettes différentes : celles des fichiers audio, celles que tu as choisies, celles des albums.
    static func items(_ library: Library) -> [GalleryItem] {
        var seen = Set<String>()
        var result: [GalleryItem] = []
        func add(_ file: String, kind: ArtworkKind, base: Track, title: String, subtitle: String, custom: Bool) {
            guard seen.insert(file).inserted else { return }
            var t = base
            if custom {
                t.customArtwork = file
                t.customKind = kind
            } else {
                t.customArtwork = nil
                t.customKind = nil
            }
            result.append(GalleryItem(id: file, url: Library.artDir.appendingPathComponent(file), kind: kind,
                                      title: title, subtitle: subtitle, track: t))
        }
        for album in library.albums {
            let cover = album.cover
            if let c = cover.customArtwork {
                add(c, kind: cover.customKind ?? .image, base: cover, title: album.title, subtitle: album.artist, custom: true)
            } else if let e = cover.embeddedArtwork {
                add(e, kind: .image, base: cover, title: album.title, subtitle: album.artist, custom: false)
            }
            for t in album.tracks {
                if let c = t.customArtwork {
                    add(c, kind: t.customKind ?? .image, base: t, title: t.title, subtitle: t.displayArtist, custom: true)
                }
                if let e = t.embeddedArtwork {
                    add(e, kind: .image, base: t, title: album.title, subtitle: album.artist, custom: false)
                }
            }
        }
        return result
    }
}

/// Une pochette en grand, avec sa résolution et le bouton pour l'enregistrer.
struct ArtworkViewer: View {
    let item: GalleryItem
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ArtworkView(track: item.track, animated: true, cornerRadius: 4, bordered: false)
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, 12)
                .scaleEffect(scale)
                .gesture(
                    MagnifyGesture()
                        .onChanged { scale = min(4, max(1, $0.magnification)) }
                        .onEnded { _ in withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { scale = 1 } }
                )
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.bold))
                            .frame(width: 40, height: 40)
                            .glassCircle()
                    }
                    .accessibilityLabel("Fermer")
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                Spacer()
                VStack(spacing: 4) {
                    Text(item.title).font(.title3.bold()).lineLimit(1)
                    Text(item.subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    Text(details).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.45)).padding(.top, 2)
                }
                .padding(.horizontal, 24)
                ShareLink(item: item.url) {
                    Label("Enregistrer ou partager", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 13)
                        .glassCapsule(interactive: true)
                }
                .padding(.top, 14)
                .padding(.bottom, 20)
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    /// « 3000 × 3000 · JPG · 2,4 Mo » : la vraie taille du fichier d'origine.
    private var details: String {
        var parts: [String] = []
        if item.kind == .image || item.kind == .gif,
           let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            parts.append("\(w) × \(h)")
        }
        if item.kind == .video { parts.append("Vidéo") }
        parts.append(item.url.pathExtension.uppercased())
        if let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }
}

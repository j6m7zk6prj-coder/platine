import SwiftUI
import ImageIO
import AVFoundation

/// Une pochette de la bibliothèque (fichier d'origine, en pleine résolution).
struct GalleryItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let kind: ArtworkKind
    let title: String
    let subtitle: String
}

// MARK: - Images de la galerie (chargées en arrière-plan, jamais pendant le défilement)

/// Miniatures et grandes images lues directement dans le fichier, réduites à la bonne taille,
/// hors du fil principal : la grille défile sans à-coup même avec beaucoup de vidéos.
actor GalleryImages {
    static let shared = GalleryImages()
    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 120 * 1024 * 1024
        return c
    }()
    private var sizes: [String: CGSize] = [:]

    func image(_ item: GalleryItem, maxPixel: Int) async -> UIImage? {
        let key = "\(item.id)|\(maxPixel)" as NSString
        if let img = cache.object(forKey: key) { return img }
        var img: UIImage?
        switch item.kind {
        case .image, .gif:
            img = Self.downsample(item.url, maxPixel: maxPixel)
        case .video:
            let asset = AVURLAsset(url: item.url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            let duration = (try? await asset.load(.duration))?.seconds ?? 1
            let at = CMTime(seconds: max(0, min(duration * 0.3, duration - 0.1)), preferredTimescale: 600)
            if let result = try? await gen.image(at: at) { img = UIImage(cgImage: result.image) }
        }
        if let img, let cg = img.cgImage {
            cache.setObject(img, forKey: key, cost: cg.bytesPerRow * cg.height)
            sizes[item.id] = CGSize(width: cg.width, height: cg.height)
        }
        return img
    }

    /// Taille réelle du fichier (largeur × hauteur en pixels).
    func pixelSize(_ item: GalleryItem) async -> CGSize? {
        if let s = sizes[item.id], item.kind == .video { return s }
        switch item.kind {
        case .image, .gif:
            guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return CGSize(width: w, height: h)
        case .video:
            let asset = AVURLAsset(url: item.url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize),
                  let t = try? await track.load(.preferredTransform) else { return nil }
            let r = size.applying(t)
            return CGSize(width: abs(r.width), height: abs(r.height))
        }
    }

    private static func downsample(_ url: URL, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Une image de la galerie, chargée à sa taille (miniature ou grand format).
private struct GalleryImage: View {
    let item: GalleryItem
    let maxPixel: Int
    var fill = true
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
                    .transition(.opacity)
            } else {
                Color(.secondarySystemFill)
                    .overlay { ProgressView() }
            }
        }
        .animation(.easeOut(duration: 0.2), value: image != nil)
        .task(id: item.id + "\(maxPixel)") {
            image = await GalleryImages.shared.image(item, maxPixel: maxPixel)
        }
    }
}

// MARK: - La grille

/// Toutes les pochettes, images et animations : touche-en une pour la voir en grand,
/// puis fais défiler les autres d'un glissement de doigt.
struct ArtworkGalleryView: View {
    @Environment(Library.self) private var library
    @State private var filter = 0
    @State private var all: [GalleryItem] = []
    @State private var opened: GalleryOpen?

    private let columns = [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)]

    private var shown: [GalleryItem] {
        switch filter {
        case 1: return all.filter { $0.kind == .image }
        case 2: return all.filter { $0.kind != .image }
        default: return all
        }
    }

    var body: some View {
        let items = shown
        ScrollView {
            Picker("Filtre", selection: $filter) {
                Text("Toutes").tag(0)
                Text("Images").tag(1)
                Text("Animées").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button { opened = GalleryOpen(items: items, index: index) } label: {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay { GalleryImage(item: item, maxPixel: 300) }
                            .clipped()
                            .contentShape(Rectangle())
                            .overlay(alignment: .bottomLeading) {
                                if item.kind != .image {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(6)
                                        .background(Circle().fill(.black.opacity(0.55)))
                                        .foregroundStyle(.white)
                                        .padding(6)
                                }
                            }
                    }
                    .buttonStyle(PressStyle(circle: false))
                }
            }
            .padding(.horizontal, 3)

            if items.isEmpty {
                ContentUnavailableView("Aucune pochette", systemImage: "photo.on.rectangle",
                                       description: Text(filter == 2 ? "Aucune pochette animée pour l’instant." : "Importe de la musique pour voir ses pochettes."))
                    .padding(.top, 60)
            }
        }
        .navigationTitle("Pochettes")
        .navigationBarTitleDisplayMode(.large)
        .task(id: library.artworkRevision) { all = Self.items(library) }
        .fullScreenCover(item: $opened) { open in
            ArtworkPager(items: open.items, start: open.index)
        }
    }

    /// Toutes les pochettes différentes : celles des fichiers audio, celles que tu as choisies,
    /// celles des albums, et les pochettes animées.
    static func items(_ library: Library) -> [GalleryItem] {
        var seen = Set<String>()
        var result: [GalleryItem] = []
        func add(_ file: String, _ kind: ArtworkKind, _ title: String, _ subtitle: String) {
            guard seen.insert(file).inserted else { return }
            let url = Library.artDir.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            result.append(GalleryItem(id: file, url: url, kind: kind, title: title, subtitle: subtitle))
        }
        for album in library.albums {
            let cover = album.cover
            if let still = library.stillURL(cover) { add(still.lastPathComponent, .image, album.title, album.artist) }
            if let m = library.motion(cover) { add(m.url.lastPathComponent, m.kind, album.title, album.artist + " · animée") }
            for t in album.tracks {
                if let c = t.customArtwork { add(c, t.customKind ?? .image, t.title, t.displayArtist) }
                if let e = t.embeddedArtwork { add(e, .image, album.title, album.artist) }
                if let m = t.motionArtwork { add(m, t.motionKind ?? .video, t.title, t.displayArtist + " · animée") }
            }
        }
        return result
    }
}

struct GalleryOpen: Identifiable {
    let id = UUID()
    let items: [GalleryItem]
    let index: Int
}

// MARK: - Le visionneur : on glisse d'une pochette à l'autre

struct ArtworkPager: View {
    let items: [GalleryItem]
    let start: Int
    @Environment(\.dismiss) private var dismiss
    @State private var current: String = ""
    @State private var chromeHidden = false
    @State private var dragDown: CGFloat = 0
    @State private var zoomed = false

    private var index: Int { items.firstIndex { $0.id == current } ?? 0 }

    var body: some View {
        let item = items.indices.contains(index) ? items[index] : items.first
        ZStack {
            // Comme Photos : fond blanc (ou noir en thème sombre) ; un toucher cache tout et passe au noir.
            (chromeHidden ? Color.black : Color(.systemBackground))
                .opacity(1 - min(0.6, Double(dragDown / 500)))
                .ignoresSafeArea()

            TabView(selection: $current) {
                ForEach(items) { it in
                    ArtworkPage(item: it, active: it.id == current, zoomed: $zoomed,
                                onTap: { withAnimation(.easeOut(duration: 0.2)) { chromeHidden.toggle() } })
                        .tag(it.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .offset(y: dragDown)
            .scaleEffect(1 - min(0.2, dragDown / 2000))
            // Glisser vers le bas pour fermer (quand on ne zoome pas).
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { g in
                        guard !zoomed, g.translation.height > 0, abs(g.translation.height) > abs(g.translation.width) else { return }
                        dragDown = g.translation.height
                    }
                    .onEnded { g in
                        if dragDown > 140 || g.predictedEndTranslation.height > 400 { dismiss() }
                        else { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dragDown = 0 } }
                    }
            )

            if let item, !chromeHidden {
                chrome(item)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(.primary)
        .animation(.easeOut(duration: 0.2), value: chromeHidden)
        .statusBarHidden(chromeHidden)
        .onAppear { if current.isEmpty, items.indices.contains(start) { current = items[start].id } }
        .onChange(of: current) { _, _ in zoomed = false }
        .sensoryFeedback(.selection, trigger: current)
    }

    private func chrome(_ item: GalleryItem) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button("OK") { dismiss() }
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Fermer")
                Spacer()
                Text("\(index + 1) sur \(items.count)")
                    .font(.headline.monospacedDigit())
                Spacer()
                ShareLink(item: item.url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body)
                        .foregroundStyle(.tint)
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("Enregistrer ou partager")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.bar, ignoresSafeAreaEdges: .top)
            .overlay(alignment: .bottom) { Divider() }

            Spacer()

            VStack(spacing: 4) {
                Text(item.title).font(.title3.bold()).lineLimit(1)
                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                GalleryDetails(item: item)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            // Bande de miniatures : touche pour sauter directement à une pochette.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 4) {
                        ForEach(items) { it in
                            Button {
                                withAnimation(.smooth(duration: 0.3)) { current = it.id }
                            } label: {
                                GalleryImage(item: it, maxPixel: 120)
                                    .frame(width: it.id == current ? 46 : 34, height: 46)
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(it.id == current ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear), lineWidth: 1.5))
                                    .opacity(it.id == current ? 1 : 0.6)
                            }
                            .buttonStyle(.plain)
                            .id(it.id)
                        }
                    }
                    .padding(.horizontal, UIScreen.main.bounds.width / 2 - 23)
                    .animation(.smooth(duration: 0.25), value: current)
                }
                .frame(height: 50)
                .onAppear { proxy.scrollTo(current, anchor: .center) }
                .onChange(of: current) { _, id in withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) } }
            }
            .padding(.bottom, 14)
        }
    }
}

/// Une page du visionneur : l'image en grand (zoom au pincement ou double toucher),
/// ou l'animation qui tourne — seulement quand la page est affichée.
private struct ArtworkPage: View {
    let item: GalleryItem
    let active: Bool
    @Binding var zoomed: Bool
    var onTap: () -> Void
    @State private var aspect: CGFloat = 1
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let fitted = fit(aspect, in: geo.size)
            media
                .frame(width: fitted.width, height: fitted.height)
                .clipped()
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        if scale > 1 { reset() } else { scale = 2.5; baseScale = 2.5; zoomed = true }
                    }
                }
                .onTapGesture { onTap() }
                .gesture(
                    MagnifyGesture()
                        .onChanged { g in
                            scale = min(5, max(1, baseScale * g.magnification))
                            zoomed = scale > 1.01
                        }
                        .onEnded { _ in
                            if scale < 1.05 { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { reset() } }
                            baseScale = scale
                        }
                )
                // Déplacer l'image zoomée (sans zoom, le glissement passe d'une pochette à l'autre).
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { g in
                            guard scale > 1.01 else { return }
                            offset = CGSize(width: baseOffset.width + g.translation.width, height: baseOffset.height + g.translation.height)
                        }
                        .onEnded { _ in baseOffset = offset },
                    including: scale > 1.01 ? .all : .subviews
                )
        }
        .ignoresSafeArea()
        .task(id: item.id) {
            if let size = await GalleryImages.shared.pixelSize(item), size.height > 0 {
                aspect = size.width / size.height
            }
        }
        .onChange(of: active) { _, on in if !on { reset() } }
    }

    @ViewBuilder private var media: some View {
        ZStack {
            // Toujours une image fixe dessous : rien de noir pendant que l'animation démarre.
            GalleryImage(item: item, maxPixel: 2400)
            if active && item.kind == .video {
                LoopingVideoView(url: item.url).transition(.opacity)
            } else if active && item.kind == .gif {
                AnimatedImageView(url: item.url).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: active)
    }

    private func reset() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
        zoomed = false
    }

    private func fit(_ aspect: CGFloat, in size: CGSize) -> CGSize {
        let a = max(0.2, min(5, aspect))
        let w = size.width, h = size.height * 0.78
        return w / h > a ? CGSize(width: h * a, height: h) : CGSize(width: w, height: w / a)
    }
}

/// « 3000 × 3000 · JPG · 2,4 Mo » : la vraie taille du fichier d'origine.
private struct GalleryDetails: View {
    let item: GalleryItem
    @State private var size: CGSize?

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.top, 2)
            .task(id: item.id) { size = await GalleryImages.shared.pixelSize(item) }
    }

    private var text: String {
        var parts: [String] = []
        if let size { parts.append("\(Int(size.width)) × \(Int(size.height))") }
        switch item.kind {
        case .video: parts.append("Vidéo")
        case .gif: parts.append("GIF animé")
        case .image: break
        }
        parts.append(item.url.pathExtension.uppercased())
        if let bytes = (try? item.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }
}

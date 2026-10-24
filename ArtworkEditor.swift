import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Vidéo choisie dans Photos, copiée dans un fichier temporaire.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

/// Changer la pochette d'un morceau, ou la pochette officielle d'un album, autant de fois qu'on veut.
struct ArtworkEditor: View {
    let trackID: UUID
    /// Rempli : on change la pochette officielle de l'album (chaque morceau garde la sienne).
    var albumID: String? = nil
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var pickerItem: PhotosPickerItem?
    @State private var showFiles = false
    @State private var applyToAlbum = false
    @State private var working = false

    var body: some View {
        NavigationStack {
            Group {
                if let t = library.track(trackID) {
                    content(t)
                } else {
                    ContentUnavailableView("Morceau introuvable", systemImage: "music.note")
                }
            }
            .navigationTitle(albumID == nil ? "Pochette du morceau" : "Pochette de l’album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }.fontWeight(.semibold)
                }
            }
            .background { AmbientBackground(track: library.track(trackID), dim: 0.45) }
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(.black)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await loadPicked(item) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image, .movie]) { result in
            if case .success(let url) = result { importFile(url) }
        }
    }

    private var album: AlbumInfo? { albumID.flatMap { library.album($0) } }

    private func content(_ track: Track) -> some View {
        // En mode album : on montre et on modifie la pochette officielle de l'album.
        let t = album?.cover ?? track
        return ScrollView {
            VStack(spacing: 26) {
                ArtworkView(track: t, cornerRadius: 20)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if working {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                                .frame(width: 70, height: 70)
                                .glass(18)
                        }
                    }
                    .shadow(color: .black.opacity(0.4), radius: 26, y: 16)
                    .padding(.horizontal, 36)
                    .padding(.top, 12)
                    .animation(.smooth(duration: 0.5), value: library.artworkURL(t))

                VStack(spacing: 4) {
                    Text(album?.title ?? t.title).font(.headline).lineLimit(1)
                    Text(album.map { $0.artist + " · album" } ?? t.subtitle)
                        .font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }

                VStack(spacing: 10) {
                    PhotosPicker(selection: $pickerItem, matching: .any(of: [.images, .videos])) {
                        row("Choisir dans Photos", detail: "Image, GIF ou vidéo", symbol: "photo.on.rectangle.angled")
                    }
                    Button { showFiles = true } label: {
                        row("Choisir dans Fichiers", detail: "JPG, PNG, HEIC, GIF, MOV, MP4", symbol: "folder")
                    }
                    if let albumID, library.hasAlbumCover(albumID) {
                        Button { library.resetAlbumCover(albumID) } label: {
                            row("Pochette d’origine", detail: "Celle du fichier audio", symbol: "arrow.uturn.backward")
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else if albumID == nil, t.customArtwork != nil {
                        Button { library.resetArtwork(targetIDs(t)) } label: {
                            row("Pochette d’origine", detail: t.embeddedArtwork == nil ? "Aucune dans le fichier" : "Celle du fichier audio",
                                symbol: "arrow.uturn.backward")
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .buttonStyle(PressStyle(circle: false))
                .disabled(working)
                .animation(.smooth, value: t.customArtwork)

                if albumID != nil {
                    Text("Seule la pochette de l’album change (bibliothèque, page de l’album, Collection). Chaque morceau garde la sienne dans le lecteur.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                } else if !t.album.isEmpty, library.albumTrackIDs(of: t).count > 1 {
                    Toggle(isOn: $applyToAlbum) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Appliquer à tout l’album").font(.body.weight(.medium))
                            Text("\(t.album) · \(library.albumTrackIDs(of: t).count) morceaux")
                                .font(.footnote).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .padding(16)
                    .glass(18)
                }

                Text("Les vidéos et GIF tournent en boucle, sans le son, dans l’app. L’écran verrouillé affiche leur première image.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .foregroundStyle(.white)
        .padding(16)
        .contentShape(Rectangle())
        .glass(18, interactive: true)
    }

    private func targetIDs(_ t: Track) -> Set<UUID> {
        applyToAlbum ? library.albumTrackIDs(of: t) : [t.id]
    }

    private func loadPicked(_ item: PhotosPickerItem) async {
        guard let t = library.track(trackID) else { return }
        let ids = targetIDs(t)
        working = true
        defer {
            working = false
            pickerItem = nil
        }
        let types = item.supportedContentTypes
        if types.contains(where: { $0.conforms(to: .movie) }) {
            if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                if let albumID { library.setAlbumCover(albumID, file: movie.url, kind: .video) }
                else { library.setCustomArtwork(ids, file: movie.url, kind: .video) }
                try? FileManager.default.removeItem(at: movie.url)
            } else {
                library.message = "Impossible de charger cette vidéo"
            }
        } else if let data = try? await item.loadTransferable(type: Data.self) {
            if types.contains(where: { $0.conforms(to: .gif) }) {
                if let albumID { library.setAlbumCover(albumID, data: data, ext: "gif", kind: .gif) }
                else { library.setCustomArtwork(ids, data: data, ext: "gif", kind: .gif) }
            } else if let image = UIImage(data: data) {
                if let albumID { library.setAlbumCover(albumID, image: image) }
                else { library.setCustomImage(ids, image: image) }
            } else {
                library.message = "Format d’image non reconnu"
            }
        } else {
            library.message = "Impossible de charger ce fichier"
        }
    }

    private func importFile(_ url: URL) {
        guard let t = library.track(trackID) else { return }
        let ids = targetIDs(t)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .gif) == true {
            if let albumID { library.setAlbumCover(albumID, file: url, kind: .gif) }
            else { library.setCustomArtwork(ids, file: url, kind: .gif) }
        } else if type?.conforms(to: .movie) == true {
            if let albumID { library.setAlbumCover(albumID, file: url, kind: .video) }
            else { library.setCustomArtwork(ids, file: url, kind: .video) }
        } else if let image = UIImage(contentsOfFile: url.path) {
            if let albumID { library.setAlbumCover(albumID, image: image) }
            else { library.setCustomImage(ids, image: image) }
        } else {
            library.message = "Format non reconnu"
        }
    }
}

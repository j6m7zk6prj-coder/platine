import SwiftUI
import PhotosUI

// MARK: - Morceaux et favoris

struct SongsView: View {
    var favoritesOnly = false
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(AppSettings.self) private var settings
    @State private var query = ""

    var body: some View {
        @Bindable var settings = settings
        let base = favoritesOnly ? library.favorites : library.tracks
        let sorted = library.sorted(base, by: settings.songSort)
        let shown = query.isEmpty ? sorted : sorted.filter { $0.matches(query) }
        List {
            if base.isEmpty {
                ContentUnavailableView(favoritesOnly ? "Aucun favori" : "Aucun morceau",
                                       systemImage: favoritesOnly ? "heart" : "music.note",
                                       description: Text(favoritesOnly ? "Touche le cœur d’un morceau pour l’ajouter ici." : "Importe de la musique avec le bouton +."))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                PlayShuffleButtons(ids: sorted.map(\.id))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                TrackRows(tracks: shown)
            }
        }
        .plainList()
        .searchable(text: $query, prompt: "Rechercher")
        .navigationTitle(favoritesOnly ? "Favoris" : "Morceaux")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Trier par", selection: $settings.songSort) {
                        ForEach(SongSort.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Trier")
            }
        }
        .background { AmbientBackground(track: player.currentID.flatMap { library.track($0) }, dim: 0.6) }
    }
}

// MARK: - Albums

struct AlbumsView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var query = ""

    var body: some View {
        let albums = library.albums.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
        }
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 22) {
                ForEach(albums) { album in
                    NavigationLink { AlbumDetailView(albumID: album.id) } label: { AlbumCard(album: album) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .searchable(text: $query, prompt: "Rechercher un album")
        .navigationTitle("Albums")
        .background { AmbientBackground(track: player.currentID.flatMap { library.track($0) }, dim: 0.6) }
    }
}

struct AlbumDetailView: View {
    let albumID: String
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(UIState.self) private var ui
    @Environment(AppSettings.self) private var settings
    /// Position de l'en-tête à l'écran (pour faire suivre la grande pochette au défilement).
    @State private var albumCoverEditing = false
    @State private var headerY: CGFloat = 0
    @State private var headerBase: CGFloat?
    /// Nouvel identifiant après une modification.
    @State private var renamedID: String?
    @State private var showEdit = false
    @State private var editTitle = ""
    @State private var editArtist = ""

    private var currentID: String { renamedID ?? albumID }

    var body: some View {
        content
            .alert("Modifier l’album", isPresented: $showEdit) {
                TextField("Titre de l’album", text: $editTitle)
                TextField("Artiste", text: $editArtist)
                Button("Enregistrer") {
                    renamedID = library.renameAlbum(currentID, title: editTitle, artist: editArtist)
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Les changements s’appliquent à tous les morceaux de l’album.")
            }
    }

    @ViewBuilder private var content: some View {
        if let album = library.album(currentID) {
            // Comme Musique : seule une pochette animée (vidéo ou GIF) s'étend en haut de la page.
            let extended = settings.extendedAlbumArtwork && settings.animatedArtwork && library.motion(album.cover) != nil
            List {
                VStack(spacing: 16) {
                    if extended {
                        // Espace laissé à la grande pochette, qui est dessinée derrière la liste.
                        Color.clear
                            .frame(height: UIScreen.main.bounds.width * 0.6)
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { y in
                                if headerBase == nil { headerBase = y }
                                headerY = y
                            }
                    } else {
                        ArtworkView(track: album.cover, animated: false, cornerRadius: 14)
                            .frame(width: 250, height: 250)
                            .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
                    }
                    VStack(spacing: 4) {
                        Text(album.title)
                            .font(extended ? .title.bold() : .title2.bold())
                            .multilineTextAlignment(.center)
                            .shadow(color: .black.opacity(extended ? 0.35 : 0), radius: 10, y: 2)
                        Text(album.artist)
                            .font(.title3)
                            .foregroundStyle(.tint)
                        Text([album.year > 0 ? "\(album.year)" : nil, songCount(album.tracks.count)].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    PlayShuffleButtons(ids: album.tracks.map(\.id))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                TrackRows(tracks: album.tracks, numbered: true, showArtwork: false)

                Text("\(songCount(album.tracks.count)), \(formatDuration(album.duration))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .plainList()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Lire ensuite", systemImage: "text.line.first.and.arrowtriangle.forward") {
                            player.playNext(album.tracks.map(\.id))
                        }
                        Button("Lire plus tard", systemImage: "text.line.last.and.arrowtriangle.forward") {
                            player.playLater(album.tracks.map(\.id))
                        }
                        Button("Ajouter à une playlist", systemImage: "text.badge.plus") {
                            ui.addToPlaylist = AddToPlaylistTarget(trackIDs: album.tracks.map(\.id))
                        }
                        if !library.isSealed(album.id) {
                            Button("Remettre sous blister", systemImage: "shippingbox") {
                                library.setSealed(album.id, true)
                            }
                        }
                        Button(library.isExposed(album.id) ? "Ranger de la Collection" : "Exposer dans la Collection",
                               systemImage: library.isExposed(album.id) ? "eye.slash" : "opticaldisc") {
                            library.setExposed(album.id, !library.isExposed(album.id))
                        }
                        Button("Changer la pochette de l’album", systemImage: "photo.on.rectangle") {
                            albumCoverEditing = true
                        }
                        Button("Modifier l’album", systemImage: "pencil") {
                            editTitle = album.title
                            editArtist = album.artist
                            showEdit = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Options de l’album")
                }
            }
            .toolbarBackground(extended ? .hidden : .automatic, for: .navigationBar)
            .sheet(isPresented: $albumCoverEditing) {
                ArtworkEditor(trackID: album.first.id, albumID: album.id)
            }
            .background {
                ZStack(alignment: .top) {
                    AmbientBackground(track: album.cover, dim: 0.5)
                    if extended {
                        ExtendedArtwork(track: album.cover, scroll: headerBase.map { headerY - $0 } ?? 0)
                    }
                }
                .ignoresSafeArea()
            }
        } else {
            ContentUnavailableView("Album introuvable", systemImage: "square.stack")
        }
    }
}

// MARK: - Artistes

struct ArtistsView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var query = ""

    var body: some View {
        let artists = library.artists.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        List {
            ForEach(artists) { artist in
                NavigationLink { ArtistDetailView(artistID: artist.id) } label: {
                    HStack(spacing: 14) {
                        ArtistAvatar(artist: artist)
                            .frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(artist.name).font(.body.weight(.medium))
                            Text("\(artist.albums.count) album\(artist.albums.count > 1 ? "s" : "") · \(songCount(artist.tracks.count))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(.primary.opacity(0.1))
            }
        }
        .plainList()
        .searchable(text: $query, prompt: "Rechercher un artiste")
        .navigationTitle("Artistes")
        .background { AmbientBackground(track: player.currentID.flatMap { library.track($0) }, dim: 0.6) }
    }
}

struct ArtistDetailView: View {
    let artistID: String
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var heroY: CGFloat = 0
    @State private var heroBase: CGFloat?
    /// Nouvel identifiant après un renommage.
    @State private var renamedID: String?
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?

    private var currentID: String { renamedID ?? artistID }

    var body: some View {
        Group {
            if let artist = library.artist(currentID) {
                content(artist)
            } else {
                ContentUnavailableView("Artiste introuvable", systemImage: "music.mic")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Renommer l’artiste", systemImage: "pencil") {
                        renameText = library.artist(currentID)?.name ?? ""
                        showRename = true
                    }
                    Button("Choisir une photo", systemImage: "photo") { showPhotoPicker = true }
                    if library.artistImages[currentID] != nil {
                        Button("Retirer la photo", systemImage: "trash", role: .destructive) {
                            library.resetArtistImage(currentID)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Options de l’artiste")
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            let id = currentID
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    library.setArtistImage(id, image: img)
                } else {
                    library.message = "Impossible de charger cette photo"
                }
                photoItem = nil
            }
        }
        .alert("Renommer l’artiste", isPresented: $showRename) {
            TextField("Nom de l’artiste", text: $renameText)
            Button("Renommer") { renamedID = library.renameArtist(currentID, to: renameText) }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le nouveau nom s’applique à tous ses morceaux.")
        }
    }

    /// Page d'artiste façon Musique (iOS 27) : grande photo en haut qui se fond dans la page,
    /// son nom en grand, ses morceaux populaires, ses albums, puis tous ses morceaux.
    private func content(_ artist: ArtistInfo) -> some View {
        let popular = Array(artist.tracks
            .sorted { $0.playCount != $1.playCount ? $0.playCount > $1.playCount : $0.title < $1.title }
            .prefix(5))
        return List {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: UIScreen.main.bounds.width * 0.78)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { y in
                        if heroBase == nil { heroBase = y }
                        heroY = y
                    }
                HStack(alignment: .bottom) {
                    Text(artist.name)
                        .font(.system(size: 34, weight: .heavy))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(0.4), radius: 12, y: 2)
                    Spacer()
                    Button {
                        player.play(ids: artist.tracks.map(\.id), shuffled: false)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 54, height: 54)
                            .background(Circle().fill(.tint))
                            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel("Lire " + artist.name)
                }
                .padding(.bottom, 6)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if !popular.isEmpty {
                Section {
                    ForEach(Array(popular.enumerated()), id: \.element.id) { i, t in
                        Button {
                            player.play(ids: popular.map(\.id), startAt: t.id)
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkView(track: t, animated: false, small: true, cornerRadius: 6)
                                    .frame(width: 48, height: 48)
                                Text("\(i + 1)").font(.headline).foregroundStyle(.secondary).frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text(t.title).font(.body.weight(.medium)).lineLimit(1)
                                        if t.explicit { ExplicitBadge(size: 13) }
                                    }
                                    Text(t.displayAlbum).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("Morceaux populaires").font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
                }
            }

            if !artist.albums.isEmpty {
                Section {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(artist.albums) { album in
                                NavigationLink { AlbumDetailView(albumID: album.id) } label: {
                                    AlbumCard(album: album).frame(width: 150)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .scrollIndicators(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    Text("Albums").font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
                }
            }

            Section {
                PlayShuffleButtons(ids: artist.tracks.map(\.id))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                TrackRows(tracks: artist.tracks)
            } header: {
                Text("Tous les morceaux").font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
            }
        }
        .plainList()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .background {
            ZStack(alignment: .top) {
                AmbientBackground(track: artist.tracks.first, dim: 0.5)
                ArtistHero(artist: artist, scroll: heroBase.map { heroY - $0 } ?? 0)
            }
            .ignoresSafeArea()
        }
    }
}

/// La grande photo de l'artiste (ou la pochette de son album) en haut de sa page.
struct ArtistHero: View {
    let artist: ArtistInfo
    let scroll: CGFloat
    @Environment(Library.self) private var library

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = w * 1.05
            let pull = max(0, scroll)
            let up = max(0, -scroll)
            Group {
                if let img = library.artistImage(artist.id) ?? artist.albums.first.flatMap({ library.image(for: $0.cover) }) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Color(white: 0.15)
                }
            }
            .frame(width: w, height: h)
            .clipped()
            .mask(
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.55),
                    .init(color: .black.opacity(0.7), location: 0.72),
                    .init(color: .black.opacity(0.3), location: 0.86),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            )
            .scaleEffect(1 + pull / w, anchor: .top)
            .offset(y: -up * 0.6)
            .opacity(Double(max(0, 1 - up / (w * 0.8))))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Playlists

struct PlaylistsView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var showNew = false
    @State private var newName = ""
    @State private var renaming: Playlist?
    @State private var renameText = ""

    var body: some View {
        List {
            Button { showNew = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "plus")
                        .font(.title3.weight(.semibold))
                        .frame(width: 56, height: 56)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.08)))
                    Text("Nouvelle playlist").font(.body.weight(.medium))
                }
                .foregroundStyle(.tint)
            }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(.primary.opacity(0.1))

            ForEach(library.sortedPlaylists) { p in
                NavigationLink { PlaylistDetailView(playlistID: p.id) } label: {
                    HStack(spacing: 14) {
                        PlaylistMosaic(playlist: p).frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(p.name).font(.body.weight(.medium)).lineLimit(1)
                                if p.pinned {
                                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tint)
                                }
                            }
                            Text(songCount(p.trackIDs.count)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(.primary.opacity(0.1))
                .swipeActions {
                    Button(role: .destructive) { library.deletePlaylist(p.id) } label: { Label("Supprimer", systemImage: "trash") }
                }
                .contextMenu {
                    Button("Lire", systemImage: "play.fill") { player.play(ids: p.trackIDs) }
                    Button(p.pinned ? "Désépingler" : "Épingler", systemImage: p.pinned ? "pin.slash" : "pin") { library.togglePin(p.id) }
                    Button("Renommer", systemImage: "pencil") { renameText = p.name; renaming = p }
                    Button("Supprimer", systemImage: "trash", role: .destructive) { library.deletePlaylist(p.id) }
                }
            }
        }
        .plainList()
        .navigationTitle("Playlists")
        .background { AmbientBackground(track: player.currentID.flatMap { library.track($0) }, dim: 0.6) }
        .alert("Nouvelle playlist", isPresented: $showNew) {
            TextField("Nom de la playlist", text: $newName)
            Button("Créer") { library.createPlaylist(name: newName); newName = "" }
            Button("Annuler", role: .cancel) { newName = "" }
        }
        .alert("Renommer la playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nom", text: $renameText)
            Button("Renommer") { if let p = renaming { library.renamePlaylist(p.id, to: renameText) }; renaming = nil }
            Button("Annuler", role: .cancel) { renaming = nil }
        }
    }
}

/// Vignette de playlist : les pochettes de ses 4 premiers albums.
struct PlaylistMosaic: View {
    let playlist: Playlist
    var cornerRadius: CGFloat = 8
    @Environment(Library.self) private var library

    /// Un morceau par album, 4 au maximum.
    private var covers: [Track] {
        var seen = Set<String>()
        var result: [Track] = []
        for t in library.tracks(playlist.trackIDs) where !seen.contains(t.albumKey) {
            seen.insert(t.albumKey)
            result.append(t)
            if result.count == 4 { break }
        }
        return result
    }

    var body: some View {
        let covers = self.covers
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if covers.count >= 4 {
                let items = covers
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ArtworkView(track: items[0], animated: false, small: true, cornerRadius: 0)
                        ArtworkView(track: items[1], animated: false, small: true, cornerRadius: 0)
                    }
                    GridRow {
                        ArtworkView(track: items[2], animated: false, small: true, cornerRadius: 0)
                        ArtworkView(track: items[3], animated: false, small: true, cornerRadius: 0)
                    }
                }
            } else if let first = covers.first {
                ArtworkView(track: first, animated: false, cornerRadius: 0)
            } else {
                shape.fill(LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        Image(systemName: "music.note.list").font(.title2).foregroundStyle(.white.opacity(0.5))
                    }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(shape)
    }
}

struct PlaylistDetailView: View {
    let playlistID: UUID
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var showPicker = false

    var body: some View {
        if let p = library.playlist(playlistID) {
            let tracks = library.tracks(p.trackIDs)
            List {
                VStack(spacing: 14) {
                    PlaylistMosaic(playlist: p, cornerRadius: 14)
                        .frame(width: 230, height: 230)
                        .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
                    VStack(spacing: 4) {
                        Text(p.name).font(.title2.bold()).multilineTextAlignment(.center)
                        Text("\(songCount(tracks.count)) · \(formatDuration(tracks.reduce(0) { $0 + $1.duration }))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    PlayShuffleButtons(ids: tracks.map(\.id))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Button { showPicker = true } label: {
                    Label("Ajouter des morceaux", systemImage: "plus.circle.fill").font(.body.weight(.medium))
                }
                .foregroundStyle(.tint)
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(.primary.opacity(0.1))

                TrackRows(tracks: tracks,
                          onDelete: { library.removeFromPlaylist(p.id, offsets: $0) },
                          onMove: { library.movePlaylistTracks(p.id, from: $0, to: $1) })
            }
            .plainList()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            .sheet(isPresented: $showPicker) {
                TrackPickerSheet(playlistID: p.id)
            }
            .background { AmbientBackground(track: tracks.first, dim: 0.5) }
        } else {
            ContentUnavailableView("Playlist introuvable", systemImage: "music.note.list")
        }
    }
}

/// Choisir plusieurs morceaux à ajouter à une playlist.
struct TrackPickerSheet: View {
    let playlistID: UUID
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var selection: [UUID] = []
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(library.tracks.filter { query.isEmpty || $0.matches(query) }) { t in
                    let picked = selection.contains(t.id)
                    Button {
                        if picked { selection.removeAll { $0 == t.id } } else { selection.append(t.id) }
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(track: t, animated: false, small: true, cornerRadius: 6)
                                .frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).lineLimit(1)
                                Text(t.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Rechercher")
            .navigationTitle("Ajouter des morceaux")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selection.isEmpty ? "Ajouter" : "Ajouter (\(selection.count))") {
                        library.add(selection, toPlaylist: playlistID)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(selection.isEmpty)
                }
            }
        }
    }
}

/// « Ajouter à une playlist » : une existante ou une nouvelle.
struct AddToPlaylistSheet: View {
    let target: AddToPlaylistTarget
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var showNew = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Button { showNew = true } label: {
                    Label("Nouvelle playlist…", systemImage: "plus").font(.body.weight(.medium))
                }
                .foregroundStyle(.tint)
                ForEach(library.sortedPlaylists) { p in
                    Button {
                        library.add(target.trackIDs, toPlaylist: p.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            PlaylistMosaic(playlist: p).frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).lineLimit(1)
                                Text(songCount(p.trackIDs.count)).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Ajouter à une playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            }
            .alert("Nouvelle playlist", isPresented: $showNew) {
                TextField("Nom de la playlist", text: $newName)
                Button("Créer") {
                    library.createPlaylist(name: newName, trackIDs: target.trackIDs)
                    newName = ""
                    dismiss()
                }
                Button("Annuler", role: .cancel) { newName = "" }
            }
        }
        .presentationDetents([.medium, .large])
    }
}


// MARK: - Grande pochette en haut de la page d'un album

/// La pochette (animée si c'est une vidéo ou un GIF) prend toute la largeur, passe sous la barre du haut
/// et se fond progressivement dans le fond. Elle suit le défilement et grandit quand on tire vers le bas.
struct ExtendedArtwork: View {
    let track: Track
    /// Défilement depuis le haut : négatif quand on monte, positif quand on tire vers le bas.
    let scroll: CGFloat

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let pull = max(0, scroll)
            let up = max(0, -scroll)
            ArtworkView(track: track, animated: true, cornerRadius: 0, bordered: false)
                .frame(width: w, height: w)
                .mask(fade)
                // Tirer vers le bas agrandit la pochette depuis le haut, comme dans Musique.
                .scaleEffect(1 + pull / w, anchor: .top)
                // En montant, elle glisse un peu moins vite que la liste (léger effet de profondeur) et s'efface.
                .offset(y: -up * 0.75)
                .opacity(Double(max(0, 1 - up / (w * 0.75))))
                .frame(width: w, alignment: .top)
        }
        .allowsHitTesting(false)
    }

    /// Fondu doux et long (courbe progressive, sans bord visible) vers le fond de la page.
    private var fade: some View {
        LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: 0.5),
            .init(color: .black.opacity(0.88), location: 0.62),
            .init(color: .black.opacity(0.62), location: 0.74),
            .init(color: .black.opacity(0.32), location: 0.85),
            .init(color: .black.opacity(0.1), location: 0.94),
            .init(color: .clear, location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }
}

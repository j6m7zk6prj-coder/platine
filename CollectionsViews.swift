import SwiftUI

// MARK: - Morceaux

struct SongsView: View {
    var favoritesOnly = false
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: AppSettings
    @State private var query = ""

    var body: some View {
        let base = favoritesOnly ? library.favorites : library.tracks
        let sorted = library.sorted(base, by: settings.songSort)
        let list = query.isEmpty ? sorted : sorted.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
        }
        List {
            if list.isEmpty {
                Text(favoritesOnly ? "Touche « Aimer » dans le menu d’un morceau pour le retrouver ici." : "Aucun morceau.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .listRowSeparator(.hidden)
            } else {
                PlayShuffleBar(ids: list.map(\.id))
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20))
                ForEach(list) { t in
                    Button { player.play(ids: list.map(\.id), startAt: t.id) } label: { TrackRow(track: t) }
                        .buttonStyle(.plain)
                        .contextMenu { TrackMenu(track: t) }
                        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 12))
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Rechercher dans les morceaux")
        .navigationTitle(favoritesOnly ? "Favoris" : "Morceaux")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Trier par", selection: $settings.songSort) {
                        ForEach(SongSort.allCases) { Text($0.label).tag($0) }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .accessibilityLabel("Trier")
            }
        }
    }
}

// MARK: - Albums

struct AlbumsView: View {
    @EnvironmentObject private var library: Library
    @State private var query = ""
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        let albums = library.albums.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
        }
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(albums) { a in
                    NavigationLink { AlbumDetailView(albumID: a.id) } label: { AlbumCell(album: a) }
                        .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .searchable(text: $query, prompt: "Rechercher dans les albums")
        .navigationTitle("Albums")
    }
}

struct AlbumDetailView: View {
    let albumID: String
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var ui: UIState

    var body: some View {
        if let album = library.album(albumID) {
            List {
                VStack(spacing: 6) {
                    Artwork(track: album.cover, cornerRadius: 8, pixels: 700)
                        .frame(width: 250, height: 250)
                        .shadow(color: .black.opacity(0.2), radius: 14, y: 8)
                        .padding(.bottom, 12)
                    Text(album.title)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                    NavigationLink { ArtistDetailView(artistID: album.artist.lowercased()) } label: {
                        Text(album.artist).font(.title3).foregroundColor(.music)
                    }
                    .buttonStyle(.plain)
                    Text(album.year > 0 ? "Album · \(String(album.year))" : "Album")
                        .font(.footnote.weight(.medium))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    PlayShuffleBar(ids: album.tracks.map(\.id))
                        .padding(.top, 14)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 14, trailing: 20))

                ForEach(Array(album.tracks.enumerated()), id: \.element.id) { i, t in
                    Button { player.play(ids: album.tracks.map(\.id), startAt: t.id) } label: {
                        TrackRow(track: t, number: t.trackNumber > 0 ? t.trackNumber : i + 1, showArtwork: false)
                            .frame(minHeight: 34)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { TrackMenu(track: t) }
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 12))
                }

                Text("\(songCount(album.tracks.count)), \(formatDuration(album.duration))")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .listRowSeparator(.hidden)
                    .padding(.top, 6)
            }
            .listStyle(.plain)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        IconButton("Lire ensuite", systemImage: "text.insert") { player.playNext(album.tracks.map(\.id)) }
                        IconButton("Lire plus tard", systemImage: "text.append") { player.playLater(album.tracks.map(\.id)) }
                        IconButton("Ajouter à une playlist…", systemImage: "text.badge.plus") {
                            ui.addToPlaylist = AddToPlaylistTarget(trackIDs: album.tracks.map(\.id))
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        } else {
            ContentUnavailableView("Album introuvable", systemImage: "square.stack")
        }
    }
}

// MARK: - Artistes

struct ArtistsView: View {
    @EnvironmentObject private var library: Library
    @State private var query = ""

    var body: some View {
        let artists = library.artists.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        List(artists) { artist in
            NavigationLink { ArtistDetailView(artistID: artist.id) } label: {
                HStack(spacing: 14) {
                    Artwork(track: artist.albums.first?.cover ?? artist.tracks.first, cornerRadius: 23, pixels: 120)
                        .frame(width: 46, height: 46)
                    Text(artist.name).font(.body)
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Rechercher dans les artistes")
        .navigationTitle("Artistes")
    }
}

struct ArtistDetailView: View {
    let artistID: String
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player

    var body: some View {
        if let artist = library.artist(artistID) {
            List {
                PlayShuffleBar(ids: artist.tracks.map(\.id))
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20))

                if !artist.albums.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Albums").font(.title3.bold())
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(artist.albums) { a in
                                    NavigationLink { AlbumDetailView(albumID: a.id) } label: {
                                        AlbumCell(album: a).frame(width: 150)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 16, trailing: 0))
                }

                Section {
                    ForEach(artist.tracks) { t in
                        Button { player.play(ids: artist.tracks.map(\.id), startAt: t.id) } label: {
                            TrackRow(track: t, subtitle: t.displayAlbum)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { TrackMenu(track: t) }
                        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 12))
                    }
                } header: {
                    Text("Morceaux").font(.title3.bold()).foregroundColor(.primary).textCase(nil)
                }
            }
            .listStyle(.plain)
            .navigationTitle(artist.name)
        } else {
            ContentUnavailableView("Artiste introuvable", systemImage: "music.mic")
        }
    }
}

// MARK: - Playlists

struct PlaylistsView: View {
    @EnvironmentObject private var library: Library
    @State private var showNew = false
    @State private var newName = ""

    var body: some View {
        List {
            Button { showNew = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "plus")
                        .font(.title2)
                        .foregroundColor(.music)
                        .frame(width: 60, height: 60)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(.secondarySystemFill)))
                    Text("Nouvelle playlist…").font(.body).foregroundColor(.music)
                }
            }
            ForEach(library.sortedPlaylists) { p in
                NavigationLink { PlaylistDetailView(playlistID: p.id) } label: {
                    HStack(spacing: 14) {
                        PlaylistArtwork(playlist: p).frame(width: 60, height: 60)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.body).lineLimit(1)
                            Text(songCount(p.trackIDs.count)).font(.subheadline).foregroundColor(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { library.deletePlaylist(p.id) } label: { Label("Supprimer", systemImage: "trash") }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Playlists")
        .alert("Nouvelle playlist", isPresented: $showNew) {
            TextField("Nom", text: $newName)
            Button("Créer") { library.createPlaylist(name: newName); newName = "" }
            Button("Annuler", role: .cancel) { newName = "" }
        }
    }
}

struct PlaylistDetailView: View {
    let playlistID: UUID
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @State private var adding = false
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        if let p = library.playlist(playlistID) {
            let tracks = library.tracks(p.trackIDs)
            List {
                VStack(spacing: 6) {
                    PlaylistArtwork(playlist: p, cornerRadius: 8)
                        .frame(width: 250, height: 250)
                        .shadow(color: .black.opacity(0.2), radius: 14, y: 8)
                        .padding(.bottom, 12)
                    Text(p.name).font(.title3.bold()).multilineTextAlignment(.center)
                    Text("\(songCount(tracks.count)) · \(formatDuration(tracks.reduce(0) { $0 + $1.duration }))")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    PlayShuffleBar(ids: tracks.map(\.id)).padding(.top, 14)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 14, trailing: 20))

                Button { adding = true } label: {
                    Label("Ajouter des morceaux", systemImage: "plus").foregroundColor(.music)
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))

                ForEach(tracks) { t in
                    Button { player.play(ids: tracks.map(\.id), startAt: t.id) } label: { TrackRow(track: t) }
                        .buttonStyle(.plain)
                        .contextMenu { TrackMenu(track: t) }
                        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 12))
                }
                .onDelete { library.removeFromPlaylist(p.id, offsets: $0) }
                .onMove { library.movePlaylistTracks(p.id, from: $0, to: $1) }
            }
            .listStyle(.plain)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        IconButton("Renommer", systemImage: "pencil") { newName = p.name; renaming = true }
                        IconButton("Supprimer la playlist", systemImage: "trash", role: .destructive) { library.deletePlaylist(p.id) }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $adding) { TrackPickerSheet(playlistID: p.id) }
            .alert("Renommer la playlist", isPresented: $renaming) {
                TextField("Nom", text: $newName)
                Button("Renommer") { library.renamePlaylist(p.id, to: newName) }
                Button("Annuler", role: .cancel) {}
            }
        } else {
            ContentUnavailableView("Playlist introuvable", systemImage: "music.note.list")
        }
    }
}

/// Choisir des morceaux à ajouter à une playlist.
struct TrackPickerSheet: View {
    let playlistID: UUID
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [UUID] = []
    @State private var query = ""

    var body: some View {
        NavigationStack {
            let list = library.tracks.filter {
                query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
            }
            List(list) { t in
                Button {
                    if let i = picked.firstIndex(of: t.id) { picked.remove(at: i) } else { picked.append(t.id) }
                } label: {
                    HStack {
                        TrackRowLite(track: t)
                        Spacer()
                        Image(systemName: picked.contains(t.id) ? "checkmark.circle.fill" : "plus.circle")
                            .font(.title3)
                            .foregroundColor(.music)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Ajouter des morceaux")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        if !picked.isEmpty { library.add(picked, toPlaylist: playlistID) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

/// Ligne de morceau sans menu (pour les listes de choix).
struct TrackRowLite: View {
    let track: Track

    var body: some View {
        HStack(spacing: 12) {
            Artwork(track: track, cornerRadius: 4, pixels: 120).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.body).lineLimit(1)
                Text(track.displayArtist).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
            }
        }
    }
}

/// « Ajouter à une playlist » : choisir la playlist (ou en créer une).
struct AddToPlaylistSheet: View {
    let target: AddToPlaylistTarget
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var showNew = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Button { showNew = true } label: {
                    Label("Nouvelle playlist…", systemImage: "plus").foregroundColor(.music)
                }
                ForEach(library.sortedPlaylists) { p in
                    Button {
                        library.add(target.trackIDs, toPlaylist: p.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 14) {
                            PlaylistArtwork(playlist: p).frame(width: 50, height: 50)
                            Text(p.name).foregroundColor(.primary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Ajouter à une playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            }
            .alert("Nouvelle playlist", isPresented: $showNew) {
                TextField("Nom", text: $newName)
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

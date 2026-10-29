import SwiftUI

/// Recherche dans toute la bibliothèque, paroles comprises.
struct SearchView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var query = ""
    @State private var scope = 0   // 0 tous, 1 albums, 2 morceaux, 3 artistes, 4 playlists

    var body: some View {
        List {
            if !query.isEmpty {
                // Filtres façon iTunes Store
                Picker("Filtre", selection: $scope) {
                    Text("Tous").tag(0)
                    Text("Albums").tag(1)
                    Text("Morceaux").tag(2)
                    Text("Artistes").tag(3)
                    Text("Playlists").tag(4)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            if query.isEmpty {
                if library.recentlyPlayed.isEmpty {
                    ContentUnavailableView("Cherche dans ta musique", systemImage: "magnifyingglass",
                                           description: Text("Titres, artistes, albums, playlists et paroles."))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    Section {
                        TrackRows(tracks: library.recentlyPlayed)
                    } header: {
                        sectionTitle("Écoutés récemment")
                    }
                }
            } else {
                results
            }
        }
        .plainList()
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Titres, artistes, albums, paroles")
        .navigationTitle("Recherche")
        .background { AmbientBackground(track: player.currentID.flatMap { library.track($0) }, dim: 0.6) }
        .onChange(of: query) { _, q in if q.isEmpty { scope = 0 } }
    }

    @ViewBuilder private var results: some View {
        let artists = library.artists.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let albums = library.albums.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) }
        let playlists = library.sortedPlaylists.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let songs = library.tracks.filter { $0.matches(query) || ($0.lyrics?.localizedCaseInsensitiveContains(query) ?? false) }

        if artists.isEmpty && albums.isEmpty && playlists.isEmpty && songs.isEmpty {
            ContentUnavailableView.search(text: query)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        if !artists.isEmpty && (scope == 0 || scope == 3) {
            Section {
                ForEach(artists.prefix(scope == 3 ? 200 : 5)) { artist in
                    NavigationLink { ArtistDetailView(artistID: artist.id) } label: {
                        HStack(spacing: 12) {
                            ArtistAvatar(artist: artist)
                                .frame(width: 44, height: 44)
                            Text(artist.name)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            } header: { sectionTitle("Artistes") }
        }
        if !albums.isEmpty && (scope == 0 || scope == 1) {
            Section {
                ForEach(albums.prefix(scope == 1 ? 200 : 6)) { album in
                    NavigationLink { AlbumDetailView(albumID: album.id) } label: {
                        HStack(spacing: 12) {
                            ArtworkView(track: album.cover, animated: false, small: true, cornerRadius: 2)
                                .frame(width: 56, height: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.title).lineLimit(1)
                                Text(album.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            } header: { sectionTitle("Albums") }
        }
        if !playlists.isEmpty && (scope == 0 || scope == 4) {
            Section {
                ForEach(playlists) { p in
                    NavigationLink { PlaylistDetailView(playlistID: p.id) } label: {
                        HStack(spacing: 12) {
                            PlaylistMosaic(playlist: p).frame(width: 44, height: 44)
                            Text(p.name).lineLimit(1)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            } header: { sectionTitle("Playlists") }
        }
        if !songs.isEmpty && (scope == 0 || scope == 2) {
            Section {
                TrackRows(tracks: songs)
            } header: { sectionTitle("Morceaux") }
        }
    }

    @ViewBuilder private func sectionTitle(_ text: String) -> some View {
        // Avec un filtre actif, pas de titre (comme l'iTunes Store) ; sinon un titre sobre.
        if scope == 0 {
            Text(text).font(.headline).foregroundStyle(.primary).textCase(nil)
        }
    }
}

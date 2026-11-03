import SwiftUI

// MARK: - Recherche dans ta bibliothèque

struct SearchView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @State private var query = ""

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        List {
            if q.isEmpty {
                Section {
                    browse("Artistes", "music.mic") { ArtistsView() }
                    browse("Albums", "square.stack") { AlbumsView() }
                    browse("Morceaux", "music.note") { SongsView() }
                    browse("Playlists", "music.note.list") { PlaylistsView() }
                } header: {
                    Text("Parcourir").font(.title3.bold()).foregroundColor(.primary).textCase(nil)
                }
            } else {
                let artists = library.artists.filter { $0.name.localizedCaseInsensitiveContains(q) }.prefix(5)
                let albums = library.albums.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q) }.prefix(8)
                let songs = library.tracks.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q) }.prefix(30)
                if artists.isEmpty && albums.isEmpty && songs.isEmpty {
                    Text("Aucun résultat pour « \(q) ».")
                        .foregroundColor(.secondary)
                        .listRowSeparator(.hidden)
                }
                if !artists.isEmpty {
                    Section("Artistes") {
                        ForEach(Array(artists)) { a in
                            NavigationLink { ArtistDetailView(artistID: a.id) } label: {
                                HStack(spacing: 14) {
                                    Artwork(track: a.albums.first?.cover ?? a.tracks.first, cornerRadius: 23, pixels: 120)
                                        .frame(width: 46, height: 46)
                                    Text(a.name)
                                }
                            }
                        }
                    }
                }
                if !albums.isEmpty {
                    Section("Albums") {
                        ForEach(Array(albums)) { a in
                            NavigationLink { AlbumDetailView(albumID: a.id) } label: {
                                HStack(spacing: 14) {
                                    Artwork(track: a.cover, cornerRadius: 4, pixels: 120).frame(width: 46, height: 46)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(a.title).lineLimit(1)
                                        Text("Album · " + a.artist).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
                if !songs.isEmpty {
                    Section("Morceaux") {
                        let ids = songs.map(\.id)
                        ForEach(Array(songs)) { t in
                            Button { player.play(ids: ids, startAt: t.id) } label: { TrackRow(track: t) }
                                .buttonStyle(.plain)
                                .contextMenu { TrackMenu(track: t) }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Artistes, morceaux, albums")
        .autocorrectionDisabled()
        .navigationTitle("Recherche")
    }

    private func browse<D: View>(_ title: String, _ icon: String, @ViewBuilder _ destination: @escaping () -> D) -> some View {
        NavigationLink(destination: LazyView(destination)) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon).foregroundColor(.music)
            }
        }
    }
}

import SwiftUI

// MARK: - Écouter (comme « Écouter » dans Musique sur iOS 16)

struct ListenNowView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var ui: UIState
    @State private var showSettings = false

    var body: some View {
        Group {
            if library.tracks.isEmpty {
                EmptyLibraryView()
            } else {
                content
            }
        }
        .navigationTitle("Écouter")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "person.crop.circle").font(.title2)
                }
                .accessibilityLabel("Réglages")
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var content: some View {
        let recents = recentAlbums
        let top = Array(library.tracks.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }.prefix(50))
        let favorites = library.favorites
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                // Les grandes cartes du haut, comme « Meilleurs choix pour vous ».
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Meilleurs choix pour vous")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            MixCard(title: "Mix favori", subtitle: "Tes titres les plus écoutés",
                                    tracks: top.isEmpty ? library.tracks : top, color: Color(red: 0.82, green: 0.17, blue: 0.29))
                            if !favorites.isEmpty {
                                MixCard(title: "Coups de cœur", subtitle: "Les titres que tu aimes",
                                        tracks: favorites, color: Color(red: 0.86, green: 0.38, blue: 0.16))
                            }
                            MixCard(title: "Toute ta musique", subtitle: songCount(library.tracks.count) + " en aléatoire",
                                    tracks: library.tracks, color: Color(red: 0.2, green: 0.36, blue: 0.75))
                        }
                        .padding(.horizontal, 20)
                    }
                }

                if !recents.isEmpty {
                    shelf("Écoutés récemment", recents)
                }
                if !library.recentlyAdded.isEmpty {
                    shelf("Ajouts récents", library.recentlyAdded)
                }

                let playlists = library.sortedPlaylists
                if !playlists.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Tes playlists") { PlaylistsView() }
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(playlists) { p in
                                    NavigationLink { PlaylistDetailView(playlistID: p.id) } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            PlaylistArtwork(playlist: p).padding(.bottom, 4)
                                            Text(p.name).font(.footnote.weight(.medium)).foregroundColor(.primary).lineLimit(1)
                                            Text(songCount(p.trackIDs.count)).font(.footnote).foregroundColor(.secondary)
                                        }
                                        .frame(width: 160)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                }

                if !top.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: "Les plus écoutés")
                        VStack(spacing: 0) {
                            ForEach(Array(top.prefix(8).enumerated()), id: \.element.id) { i, t in
                                Button { player.play(ids: top.map(\.id), startAt: t.id) } label: {
                                    TrackRow(track: t)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { TrackMenu(track: t) }
                                if i < min(top.count, 8) - 1 { Divider().padding(.leading, 80) }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func shelf(_ title: String, _ albums: [AlbumInfo]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title) { AlbumsView() }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(albums) { a in
                        NavigationLink { AlbumDetailView(albumID: a.id) } label: {
                            AlbumCell(album: a).frame(width: 160)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    /// Albums écoutés récemment, sans doublon.
    private var recentAlbums: [AlbumInfo] {
        let byID = Dictionary(library.albums.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var out: [AlbumInfo] = []
        for t in library.recentlyPlayed where seen.insert(t.albumKey).inserted {
            if let a = byID[t.albumKey] { out.append(a) }
            if out.count >= 12 { break }
        }
        return out
    }
}

/// Grande carte de mix : couleur unie, trois pochettes, lecture aléatoire au toucher.
private struct MixCard: View {
    let title: String
    let subtitle: String
    let tracks: [Track]
    let color: Color
    @EnvironmentObject private var player: Player

    var body: some View {
        Button { player.play(ids: tracks.map(\.id), shuffled: true) } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: -24) {
                    ForEach(Array(tracks.prefix(3).enumerated()), id: \.offset) { i, t in
                        Artwork(track: t, cornerRadius: 6, pixels: 240)
                            .frame(width: 92, height: 92)
                            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                            .zIndex(Double(3 - i))
                    }
                }
                .padding(.top, 22)
                .padding(.leading, 18)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title3.bold())
                    Text(subtitle).font(.subheadline).opacity(0.8).lineLimit(2)
                }
                .foregroundColor(.white)
                .padding(16)
            }
            .frame(width: 250, height: 250, alignment: .leading)
            .background(
                LinearGradient(colors: [color, color.opacity(0.75)], startPoint: .top, endPoint: .bottom)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), lecture aléatoire")
    }
}

/// Bibliothèque vide : un bouton pour importer.
struct EmptyLibraryView: View {
    @EnvironmentObject private var ui: UIState

    var body: some View {
        ContentUnavailableView {
            Label("Ta bibliothèque est vide", systemImage: "music.note")
        } description: {
            Text("Importe tes fichiers audio depuis l’app Fichiers, ou dépose-les dans le dossier Platine sur ton ordinateur.")
        } actions: {
            Button { ui.importing = true } label: {
                Text("Importer de la musique").font(.body.weight(.semibold)).padding(.horizontal, 10)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

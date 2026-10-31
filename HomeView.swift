import SwiftUI

// MARK: - Accueil (comme « Écouter maintenant » dans Musique)

/// La page d'accueil : reprendre l'écoute, tes mix, écoutés récemment, ajouts récents et tes artistes.
struct HomeView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(UIState.self) private var ui

    private var currentTrack: Track? { player.currentID.flatMap { library.track($0) } }

    /// Albums écoutés récemment (sans doublon), du plus récent au plus ancien.
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

    var body: some View {
        Group {
            if library.tracks.isEmpty {
                EmptyLibraryView()
            } else {
                content
            }
        }
        .navigationTitle("Accueil")
        .background { Color(.systemBackground).ignoresSafeArea() }
    }

    private var content: some View {
        let recents = recentAlbums
        let resume = recents.first ?? library.recentlyAdded.first
        let top = Array(library.tracks.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }.prefix(5))
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(Date.now.formatted(Date.FormatStyle(locale: Locale(identifier: "fr_FR")).weekday(.wide).day().month(.wide)).uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)

                if let resume {
                    // Comme la fiche d'un album dans l'iTunes Store.
                    HeroAlbumCard(album: resume, label: recents.isEmpty ? "À DÉCOUVRIR" : "REPRENDRE L’ÉCOUTE")
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)
                    ClassicSeparator()
                }

                HomeSection(title: "Tes mix et playlists", destination: { PlaylistsView() }) {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(mixes) { mix in
                                MixCard(mix: mix)
                            }
                            // Tes playlists, juste à côté des mix (épinglées en premier).
                            ForEach(library.sortedPlaylists) { p in
                                PlaylistCard(playlist: p)
                            }
                            NewPlaylistCard()
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 20)
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.hidden)
                }

                if !top.isEmpty {
                    ClassicSeparator()
                    HomeSection(title: "Les plus écoutés") {
                        // Liste numérotée, comme le classement des morceaux de l'iTunes Store.
                        VStack(spacing: 0) {
                            ForEach(Array(top.enumerated()), id: \.element.id) { i, t in
                                ChartRow(rank: i + 1, track: t, ids: top.map(\.id), last: i == top.count - 1)
                            }
                        }
                    }
                }

                // Clips vidéo et edits format TikTok.
                HomeClipSections()

                if recents.count > 1 {
                    ClassicSeparator()
                    HomeSection(title: "Écoutés récemment") {
                        albumShelf(Array(recents.dropFirst()))
                    }
                }

                if !library.recentlyAdded.isEmpty {
                    ClassicSeparator()
                    HomeSection(title: "Ajouts récents", destination: { AlbumsView() }) {
                        albumShelf(library.recentlyAdded)
                    }
                }

                let artists = topArtists
                if !artists.isEmpty {
                    ClassicSeparator()
                    HomeSection(title: "Tes artistes", destination: { ArtistsView() }) {
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 16) {
                                ForEach(artists.prefix(15)) { artist in
                                    NavigationLink { ArtistDetailView(artistID: artist.id) } label: {
                                        VStack(spacing: 8) {
                                            ArtistAvatar(artist: artist)
                                                .frame(width: 96, height: 96)
                                                .overlay(Circle().strokeBorder(Color(.separator), lineWidth: 0.5))
                                            Text(artist.name)
                                                .font(.footnote)
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                                .frame(width: 96)
                                        }
                                    }
                                    .buttonStyle(PressStyle(circle: false))
                                }
                            }
                            .scrollTargetLayout()
                            .padding(.horizontal, 20)
                        }
                        .scrollTargetBehavior(.viewAligned)
                        .scrollIndicators(.hidden)
                    }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
    }

    /// Tes artistes, du plus écouté au moins écouté.
    private var topArtists: [ArtistInfo] {
        func plays(_ a: ArtistInfo) -> Int { a.tracks.reduce(0) { $0 + $1.playCount } }
        return library.artists.sorted { plays($0) > plays($1) }
    }

    private func albumShelf(_ albums: [AlbumInfo]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(albums) { album in
                    NavigationLink { AlbumDetailView(albumID: album.id) } label: {
                        AlbumCard(album: album).frame(width: 140)
                    }
                    .buttonStyle(PressStyle(circle: false))
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
    }

    /// Mix générés à partir de ta bibliothèque.
    private var mixes: [HomeMix] {
        let all = library.tracks
        var out: [HomeMix] = []
        let top = all.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }.prefix(50)
        if !top.isEmpty {
            out.append(HomeMix(id: "top", title: "Mix favori", subtitle: "Tes titres les plus écoutés",
                               tracks: Array(top), colors: [Color(red: 0.95, green: 0.25, blue: 0.35), Color(red: 0.55, green: 0.1, blue: 0.4)]))
        }
        let favs = library.favorites
        if !favs.isEmpty {
            out.append(HomeMix(id: "favs", title: "Coups de cœur", subtitle: "Les titres que tu as aimés",
                               tracks: favs, colors: [Color(red: 1, green: 0.45, blue: 0.3), Color(red: 0.85, green: 0.15, blue: 0.25)]))
        }
        let fresh = all.filter { $0.playCount == 0 }
        if !fresh.isEmpty {
            out.append(HomeMix(id: "new", title: "À découvrir", subtitle: "Jamais écoutés",
                               tracks: fresh, colors: [Color(red: 0.25, green: 0.55, blue: 1), Color(red: 0.3, green: 0.2, blue: 0.75)]))
        }
        out.append(HomeMix(id: "all", title: "Toute ta musique", subtitle: "\(all.count) titres en aléatoire",
                           tracks: all, colors: [Color(red: 0.2, green: 0.75, blue: 0.6), Color(red: 0.1, green: 0.35, blue: 0.45)]))
        return out
    }
}

/// Titre de section façon Musique : gros titre, chevron s'il mène quelque part.
struct HomeSection<Content: View, Destination: View>: View {
    let title: String
    var destination: (() -> Destination)?
    @ViewBuilder var content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) where Destination == EmptyView {
        self.title = title
        self.destination = nil
        self.content = content
    }

    init(title: String, destination: @escaping () -> Destination, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.destination = destination
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Comme l'iTunes Store : titre en gras à gauche, « Tout voir › » en bleu à droite.
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.bold())
                Spacer()
                if let destination {
                    NavigationLink {
                        destination()
                    } label: {
                        HStack(spacing: 2) {
                            Text("Tout voir")
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                        }
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            content()
        }
        .padding(.vertical, 16)
    }
}

/// Fin trait gris entre deux sections, décalé à gauche comme dans les listes iOS.
struct ClassicSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 0.5)
            .padding(.leading, 20)
    }
}

/// Une ligne du classement : numéro, pochette, titre / artiste, durée et bouton « Lire » à contour.
private struct ChartRow: View {
    let rank: Int
    let track: Track
    let ids: [UUID]
    let last: Bool
    @Environment(Player.self) private var player

    var body: some View {
        let current = player.currentID == track.id
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 18)
            ArtworkView(track: track, animated: false, small: true, cornerRadius: 3)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(current ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    if track.explicit { ExplicitBadge(size: 12) }
                }
                Text(track.displayArtist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(formatTime(track.duration))
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                if let i = ids.firstIndex(of: track.id) { player.play(ids: Array(ids[i...]), shuffled: false) }
            } label: {
                Image(systemName: current && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.caption)
            }
            .buttonStyle(OutlineButtonStyle(compact: true))
            .accessibilityLabel("Lire \(track.title)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            if !last {
                Rectangle().fill(Color(.separator)).frame(height: 0.5).padding(.leading, 110)
            }
        }
    }
}

/// Grande carte « Reprendre l'écoute » : la pochette, ses couleurs en fond, et Lire / Aléatoire.
private struct HeroAlbumCard: View {
    let album: AlbumInfo
    var label: String
    @Environment(Player.self) private var player

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            NavigationLink { AlbumDetailView(albumID: album.id) } label: {
                ArtworkView(track: album.cover, animated: true, cornerRadius: 2)
                    .frame(width: 120, height: 120)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            }
            .buttonStyle(PressStyle(circle: false))
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                NavigationLink { AlbumDetailView(albumID: album.id) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(album.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 2) {
                            Text(album.artist).lineLimit(1)
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Button { player.play(ids: album.tracks.map(\.id), shuffled: false) } label: {
                        Label("Lire", systemImage: "play.fill")
                    }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                    Button { player.play(ids: album.tracks.map(\.id), shuffled: true) } label: {
                        Image(systemName: "shuffle")
                    }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                    .accessibilityLabel("Aléatoire")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        }
    }

    private var details: String {
        let n = album.tracks.count
        var parts = ["\(n) morceau\(n > 1 ? "x" : "")"]
        if album.year > 0 { parts.append("Sortie : \(album.year)") }
        return parts.joined(separator: " · ")
    }
}

struct HomeMix: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let tracks: [Track]
    let colors: [Color]
}

/// Carte d'un mix : quatre pochettes en mosaïque avec un fin cadre, le titre et le sous-titre dessous.
private struct MixCard: View {
    let mix: HomeMix
    @Environment(Player.self) private var player

    var body: some View {
        Button { player.play(ids: mix.tracks.map(\.id), shuffled: true) } label: {
            VStack(alignment: .leading, spacing: 6) {
                let covers = Array(mix.tracks.prefix(4))
                ZStack(alignment: .bottomTrailing) {
                    Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow { tile(covers, 0); tile(covers, 1) }
                        GridRow { tile(covers, 2); tile(covers, 3) }
                    }
                    .frame(width: 150, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
                    // Petite pastille de couleur du mix, comme les bandeaux des sélections iTunes.
                    Image(systemName: "shuffle")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(mix.colors[0]))
                        .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                        .padding(6)
                }
                Text(mix.title).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                Text(mix.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
        }
        .buttonStyle(PressStyle(circle: false))
        .accessibilityLabel("\(mix.title), lecture aléatoire")
    }

    @ViewBuilder private func tile(_ covers: [Track], _ i: Int) -> some View {
        Group {
            if covers.indices.contains(i) {
                ArtworkView(track: covers[i], animated: false, small: true, cornerRadius: 0, bordered: false)
            } else if let first = covers.first {
                ArtworkView(track: first, animated: false, small: true, cornerRadius: 0, bordered: false)
            } else {
                Rectangle().fill(mix.colors[0])
            }
        }
        .frame(width: 75, height: 75)
        .clipped()
    }
}

/// Carte d'une playlist dans la rangée des mix : mosaïque de pochettes, nom et nombre de morceaux.
private struct PlaylistCard: View {
    let playlist: Playlist

    var body: some View {
        NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                PlaylistMosaic(playlist: playlist, cornerRadius: 3)
                    .frame(width: 150, height: 150)
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: playlist.pinned ? "pin.fill" : "music.note.list")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(.tint))
                            .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                            .padding(6)
                    }
                Text(playlist.name).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                Text("Playlist · " + songCount(playlist.trackIDs.count)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
        }
        .buttonStyle(PressStyle(circle: false))
    }
}

/// « Nouvelle playlist » au bout de la rangée.
private struct NewPlaylistCard: View {
    @Environment(Library.self) private var library
    @State private var asking = false
    @State private var name = ""

    var body: some View {
        Button { asking = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                VStack(spacing: 8) {
                    Image(systemName: "plus").font(.title2.weight(.semibold))
                    Text("Nouvelle playlist").font(.footnote.weight(.semibold))
                }
                .foregroundStyle(.tint)
                .frame(width: 150, height: 150)
                .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])))
                Text(" ").font(.subheadline)
            }
        }
        .buttonStyle(PressStyle(circle: false))
        .alert("Nouvelle playlist", isPresented: $asking) {
            TextField("Nom de la playlist", text: $name)
            Button("Créer") { library.createPlaylist(name: name); name = "" }
            Button("Annuler", role: .cancel) { name = "" }
        }
    }
}

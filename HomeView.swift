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
        .background { AmbientBackground(track: currentTrack, dim: 0.55) }
    }

    private var content: some View {
        let recents = recentAlbums
        let resume = recents.first ?? library.recentlyAdded.first
        return ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, -18)

                if let resume {
                    HomeSection(title: recents.isEmpty ? "À découvrir" : "Reprendre l’écoute") {
                        HeroAlbumCard(album: resume)
                            .padding(.horizontal, 20)
                    }
                }

                HomeSection(title: "Tes mix") {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 14) {
                            ForEach(mixes) { mix in
                                MixCard(mix: mix)
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 20)
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.hidden)
                }

                if recents.count > 1 {
                    HomeSection(title: "Écoutés récemment") {
                        albumShelf(Array(recents.dropFirst()))
                    }
                }

                if !library.recentlyAdded.isEmpty {
                    HomeSection(title: "Ajouts récents", destination: { AlbumsView() }) {
                        albumShelf(library.recentlyAdded)
                    }
                }

                let artists = topArtists
                if !artists.isEmpty {
                    HomeSection(title: "Tes artistes", destination: { ArtistsView() }) {
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 18) {
                                ForEach(artists.prefix(15)) { artist in
                                    NavigationLink { ArtistDetailView(artistID: artist.id) } label: {
                                        VStack(spacing: 8) {
                                            ArtistAvatar(artist: artist)
                                                .frame(width: 112, height: 112)
                                                .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
                                            Text(artist.name)
                                                .font(.subheadline.weight(.medium))
                                                .lineLimit(1)
                                                .frame(width: 112)
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
            .padding(.top, 8)
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
                        AlbumCard(album: album).frame(width: 160)
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
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if let destination {
                    NavigationLink {
                        destination()
                    } label: {
                        HStack(spacing: 4) {
                            Text(title)
                            Image(systemName: "chevron.right")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(title)
                }
            }
            .font(.title2.bold())
            .padding(.horizontal, 20)
            content()
        }
    }
}

/// Grande carte « Reprendre l'écoute » : la pochette, ses couleurs en fond, et Lire / Aléatoire.
private struct HeroAlbumCard: View {
    let album: AlbumInfo
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        let colors = library.palette(for: album.cover)
        NavigationLink { AlbumDetailView(albumID: album.id) } label: {
            HStack(spacing: 16) {
                ArtworkView(track: album.cover, animated: true, cornerRadius: 12)
                    .frame(width: 128, height: 128)
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                VStack(alignment: .leading, spacing: 4) {
                    Text(album.year > 0 ? "ALBUM · \(String(album.year))" : "ALBUM")
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.65))
                    Text(album.title)
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(album.artist)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    HStack(spacing: 8) {
                        Button { player.play(ids: album.tracks.map(\.id), shuffled: false) } label: {
                            Label("Lire", systemImage: "play.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 16)
                                .frame(height: 34)
                                .background(Capsule().fill(.white))
                        }
                        Button { player.play(ids: album.tracks.map(\.id), shuffled: true) } label: {
                            Image(systemName: "shuffle")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(.white.opacity(0.22)))
                        }
                        .accessibilityLabel("Aléatoire")
                    }
                    .buttonStyle(PressStyle(circle: false))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background {
                ZStack {
                    LinearGradient(colors: [colors[0], colors[1]], startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let img = library.backdrop(for: album.cover) {
                        Image(uiImage: img).resizable().scaledToFill().opacity(0.55)
                    }
                    LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: colors[0].opacity(0.35), radius: 20, y: 10)
        }
        .buttonStyle(PressStyle(circle: false))
    }
}

struct HomeMix: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let tracks: [Track]
    let colors: [Color]
}

/// Carte d'un mix : dégradé, trois pochettes empilées, lecture aléatoire au toucher.
private struct MixCard: View {
    let mix: HomeMix
    @Environment(Player.self) private var player

    var body: some View {
        Button { player.play(ids: mix.tracks.map(\.id), shuffled: true) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: mix.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    // Pochettes du mix, en éventail.
                    let covers = Array(mix.tracks.prefix(3))
                    ZStack {
                        ForEach(Array(covers.enumerated().reversed()), id: \.offset) { i, t in
                            ArtworkView(track: t, animated: false, small: true, cornerRadius: 8)
                                .frame(width: 84, height: 84)
                                .shadow(color: .black.opacity(0.3), radius: 6, y: 4)
                                .rotationEffect(.degrees(Double(i) * 7 - 7))
                                .offset(x: CGFloat(i) * 26, y: CGFloat(i) * -6)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 18)
                    .padding(.trailing, 64)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(mix.title).font(.title3.bold())
                        Text(mix.subtitle).font(.caption.weight(.medium)).opacity(0.8)
                    }
                    .foregroundStyle(.white)
                    .padding(14)

                    Image(systemName: "play.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.black.opacity(0.25)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(12)
                }
                .frame(width: 230, height: 230)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            }
        }
        .buttonStyle(PressStyle(circle: false))
        .accessibilityLabel("\(mix.title), lecture aléatoire")
    }
}

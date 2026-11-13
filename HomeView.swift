import SwiftUI

// MARK: - Accueil (comme « Écouter maintenant » dans Musique)

/// La page d'accueil : reprendre l'écoute, tes mix, écoutés récemment, ajouts récents et tes artistes.
struct HomeView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var ui: UIState
    @State private var showSettings = false
    @State private var showGallery = false
    @State private var showOrganizer = false
    @ObservedObject private var layout: HomeLayout = .shared

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
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { layout.editing.toggle() }
                } label: {
                    Text(layout.editing ? "OK" : "Modifier").fontWeight(layout.editing ? .bold : .regular)
                }
                .disabled(library.tracks.isEmpty)
            }
            // Comme Musique : le profil en haut à droite ouvre les réglages.
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityLabel("Réglages")
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("OK") { showSettings = false }.fontWeight(.semibold)
                        }
                    }
            }
        }
        .background { AmbientBackground(track: currentTrack, dim: 0.55) }
    }

    private var content: some View {
        let items = layout.items
        return ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                Text(Date.now.formatted(Date.FormatStyle(locale: Locale(identifier: "fr_FR")).weekday(.wide).day().month(.wide)).capitalized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, -18)

                if layout.editing {
                    // Comme l'écran d'accueil : ajouter, tout ranger, terminer.
                    HStack(spacing: 10) {
                        Button { showGallery = true } label: {
                            Label("Ajouter", systemImage: "plus").font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                        Button { showOrganizer = true } label: {
                            Label("Ranger", systemImage: "list.bullet").font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                        Spacer()
                        Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { layout.editing = false } } label: {
                            Text("OK").font(.subheadline.weight(.bold))
                        }
                        .buttonStyle(FilledButtonStyle())
                    }
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    // Hors modification, une rubrique sans rien à montrer ne prend pas de place.
                    if layout.editing || hasContent(item) {
                        EditableSection(item: item, isFirst: index == 0, isLast: index == items.count - 1) {
                            section(item)
                        }
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }

                if items.isEmpty {
                    Text("Ton Accueil est vide. Touche « Modifier l’Accueil » pour y ajouter des rubriques.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                }

                if !layout.editing {
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { layout.editing = true }
                    } label: {
                        Label("Modifier l’Accueil", systemImage: "square.grid.2x2")
                    }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 30)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: items)
        }
        .scrollIndicators(.hidden)
        .sheet(isPresented: $showGallery) { HomeGallery() }
        .sheet(isPresented: $showOrganizer) { HomeOrganizer() }
    }

    /// Une rubrique de l'Accueil.
    @ViewBuilder private func section(_ item: HomeItem) -> some View {
        switch item.kind {
        case .resume:
            let recents = recentAlbums
            if let resume = recents.first ?? library.recentlyAdded.first {
                HomeSection(title: recents.isEmpty ? "À découvrir" : "Reprendre l’écoute") {
                    HeroAlbumCard(album: resume).padding(.horizontal, 20)
                }
            } else { placeholder(item) }
        case .mixes:
            HomeSection(title: "Tes mix") {
                shelf {
                    ForEach(mixes) { MixCard(mix: $0) }
                }
            }
        case .playlists:
            HomeSection(title: "Tes playlists", destination: { PlaylistsView() }) {
                shelf {
                    ForEach(library.sortedPlaylists) { PlaylistCard(playlist: $0) }
                    NewPlaylistCard()
                }
            }
        case .clips:
            HomeClipSections(showEdits: false)
        case .edits:
            HomeClipSections(showClips: false)
        case .recent:
            let recents = recentAlbums
            if recents.count > 1 {
                HomeSection(title: "Écoutés récemment") { albumShelf(Array(recents.dropFirst())) }
            } else { placeholder(item) }
        case .added:
            if !library.recentlyAdded.isEmpty {
                HomeSection(title: "Ajouts récents", destination: { AlbumsView() }) { albumShelf(library.recentlyAdded) }
            } else { placeholder(item) }
        case .artists:
            let artists = layout.orderedArtists(library.artists)
            if !artists.isEmpty {
                HomeSection(title: "Tes artistes", destination: { ArtistsView() }) {
                    shelf {
                        ForEach(artists.prefix(20)) { artist in
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
                }
            } else { placeholder(item) }
        case .artist:
            if let ref = item.ref, let a = library.artist(ref) { PinnedArtistSection(artist: a) } else { placeholder(item) }
        case .playlist:
            if let ref = item.ref, let id = UUID(uuidString: ref), let p = library.playlist(id) {
                PinnedPlaylistSection(playlist: p)
            } else { placeholder(item) }
        case .album:
            if let ref = item.ref, let a = library.album(ref) {
                HomeSection(title: a.title, destination: { AlbumDetailView(albumID: a.id) }) {
                    HeroAlbumCard(album: a).padding(.horizontal, 20)
                }
            } else { placeholder(item) }
        }
    }

    private func hasContent(_ item: HomeItem) -> Bool {
        switch item.kind {
        case .resume: return !recentAlbums.isEmpty || !library.recentlyAdded.isEmpty
        case .mixes, .playlists, .clips, .edits: return true
        case .recent: return recentAlbums.count > 1
        case .added: return !library.recentlyAdded.isEmpty
        case .artists: return !library.artists.isEmpty
        case .artist: return item.ref.flatMap { library.artist($0) } != nil
        case .playlist: return item.ref.flatMap { UUID(uuidString: $0) }.flatMap { library.playlist($0) } != nil
        case .album: return item.ref.flatMap { library.album($0) } != nil
        }
    }

    /// Rubrique vide : visible seulement quand on modifie l'Accueil (pour pouvoir la ranger ou la retirer).
    @ViewBuilder private func placeholder(_ item: HomeItem) -> some View {
        if layout.editing {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                Text(item.title + " — rien à montrer pour l’instant")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func shelf<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) { content() }
                .padding(.horizontal, 20)
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
            .padding(.horizontal, 20)
        }
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
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player

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
    @EnvironmentObject private var player: Player

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

/// Carte d'une playlist dans la rangée des mix : mosaïque de pochettes, nom et nombre de morceaux.
private struct PlaylistCard: View {
    let playlist: Playlist

    var body: some View {
        NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: {
            VStack(alignment: .leading, spacing: 8) {
                PlaylistMosaic(playlist: playlist, cornerRadius: 18)
                    .frame(width: 230, height: 230)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.22), radius: 12, y: 7)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: playlist.pinned ? "pin.fill" : "music.note.list")
                            .font(.subheadline.weight(.bold))
                            .frame(width: 34, height: 34)
                            .glassCircle()
                            .padding(12)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text("Playlist · " + songCount(playlist.trackIDs.count)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
            .frame(width: 230, alignment: .leading)
        }
        .buttonStyle(PressStyle(circle: false))
    }
}

/// « Nouvelle playlist » au bout de la rangée.
private struct NewPlaylistCard: View {
    @EnvironmentObject private var library: Library
    @State private var asking = false
    @State private var name = ""

    var body: some View {
        Button { asking = true } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus").font(.title.weight(.semibold))
                Text("Nouvelle playlist").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.tint)
            .frame(width: 230, height: 230)
            .glass(18, interactive: true)
        }
        .buttonStyle(PressStyle(circle: false))
        .alert("Nouvelle playlist", isPresented: $asking) {
            TextField("Nom de la playlist", text: $name)
            Button("Créer") { library.createPlaylist(name: name); name = "" }
            Button("Annuler", role: .cancel) { name = "" }
        }
    }
}

/// Un artiste épinglé : sa photo en grand, Lecture / Aléatoire, puis ses albums.
private struct PinnedArtistSection: View {
    let artist: ArtistInfo
    @EnvironmentObject private var player: Player

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NavigationLink { ArtistDetailView(artistID: artist.id) } label: {
                HStack(spacing: 16) {
                    ArtistAvatar(artist: artist)
                        .frame(width: 92, height: 92)
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ARTISTE").font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(.secondary)
                        Text(artist.name).font(.title2.bold()).lineLimit(2).foregroundStyle(.primary)
                        Text("\(artist.albums.count) album\(artist.albums.count > 1 ? "s" : "") · \(songCount(artist.tracks.count))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(PressStyle(circle: false))
            .padding(.horizontal, 20)

            HStack(spacing: 10) {
                Button { player.play(ids: artist.tracks.map(\.id), shuffled: false) } label: {
                    Label("Lire", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(OutlineButtonStyle())
                Button { player.play(ids: artist.tracks.map(\.id), shuffled: true) } label: {
                    Label("Aléatoire", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .buttonStyle(OutlineButtonStyle())
            }
            .padding(.horizontal, 20)

            if !artist.albums.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(artist.albums) { album in
                            NavigationLink { AlbumDetailView(albumID: album.id) } label: {
                                AlbumCard(album: album).frame(width: 140)
                            }
                            .buttonStyle(PressStyle(circle: false))
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

/// Une playlist épinglée : sa mosaïque, Lecture / Aléatoire et ses premiers titres.
private struct PinnedPlaylistSection: View {
    let playlist: Playlist
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player

    var body: some View {
        let tracks = library.tracks(playlist.trackIDs)
        VStack(alignment: .leading, spacing: 14) {
            NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: {
                HStack(spacing: 16) {
                    PlaylistMosaic(playlist: playlist, cornerRadius: 16)
                        .frame(width: 100, height: 100)
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PLAYLIST").font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(.secondary)
                        Text(playlist.name).font(.title2.bold()).lineLimit(2).foregroundStyle(.primary)
                        Text(songCount(tracks.count)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(PressStyle(circle: false))
            .padding(.horizontal, 20)

            HStack(spacing: 10) {
                Button { player.play(ids: tracks.map(\.id), shuffled: false) } label: {
                    Label("Lire", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(OutlineButtonStyle())
                Button { player.play(ids: tracks.map(\.id), shuffled: true) } label: {
                    Label("Aléatoire", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .buttonStyle(OutlineButtonStyle())
            }
            .disabled(tracks.isEmpty)
            .padding(.horizontal, 20)

            VStack(spacing: 0) {
                ForEach(tracks.prefix(4)) { t in
                    Button { player.play(ids: tracks.map(\.id), startAt: t.id) } label: {
                        HStack(spacing: 12) {
                            ArtworkView(track: t, animated: false, small: true, cornerRadius: 7).frame(width: 46, height: 46)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(.body.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
                                Text(t.displayArtist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(circle: false))
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

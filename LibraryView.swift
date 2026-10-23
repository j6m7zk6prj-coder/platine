import SwiftUI

// MARK: - Accueil de la bibliothèque

struct LibraryHomeView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(UIState.self) private var ui

    private var currentTrack: Track? { player.currentID.flatMap { library.track($0) } }

    var body: some View {
        Group {
            if library.tracks.isEmpty {
                EmptyLibraryView()
            } else {
                content
            }
        }
        .navigationTitle("Bibliothèque")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { ui.importing = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Importer de la musique")
            }
        }
        .background { AmbientBackground(track: currentTrack, dim: 0.55) }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Button { ui.showShelf = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "opticaldisc.fill")
                            .font(.title)
                            .foregroundStyle(.tint)
                            .symbolEffect(.pulse, options: .repeating, isActive: player.isPlaying)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Collection").font(.title3.weight(.semibold))
                            Text("Tes albums en CD, à prendre en main")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                    .glass(22, interactive: true)
                }
                .buttonStyle(PressStyle(circle: false))

                VStack(spacing: 0) {
                    LibraryLink(title: "Playlists", icon: "music.note.list", count: library.playlists.count) { PlaylistsView() }
                    rowDivider
                    LibraryLink(title: "Artistes", icon: "music.mic", count: library.artists.count) { ArtistsView() }
                    rowDivider
                    LibraryLink(title: "Albums", icon: "square.stack", count: library.albums.count) { AlbumsView() }
                    rowDivider
                    LibraryLink(title: "Morceaux", icon: "music.note", count: library.tracks.count) { SongsView() }
                    rowDivider
                    LibraryLink(title: "Favoris", icon: "heart", count: library.favorites.count) { SongsView(favoritesOnly: true) }
                }
                .glass(22)

                if !library.recentlyAdded.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Ajouts récents").font(.title2.bold())
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 22) {
                            ForEach(library.recentlyAdded) { album in
                                NavigationLink { AlbumDetailView(albumID: album.id) } label: { AlbumCard(album: album) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private var rowDivider: some View {
        Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 60)
    }
}

struct EmptyLibraryView: View {
    @Environment(UIState.self) private var ui

    var body: some View {
        ContentUnavailableView {
            Label("Ta bibliothèque est vide", systemImage: "music.note")
        } description: {
            Text("Importe des morceaux depuis Fichiers, ou copie-les depuis ton PC dans le dossier Platine avec iTunes.")
        } actions: {
            Button { ui.importing = true } label: {
                Text("Importer de la musique")
                    .fontWeight(.semibold)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
    }
}

struct LibraryLink<Destination: View>: View {
    let title: String
    let icon: String
    let count: Int
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                Text(title).font(.title3)
                Spacer()
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AlbumCard: View {
    let album: AlbumInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(track: album.first, animated: false, cornerRadius: 10)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
            Text(album.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(album.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Boutons Lire / Aléatoire

struct PlayShuffleButtons: View {
    let ids: [UUID]
    @Environment(Player.self) private var player

    var body: some View {
        HStack(spacing: 12) {
            Button { player.play(ids: ids, shuffled: false) } label: {
                Label("Lire", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .glass(14, interactive: true)
            }
            Button { player.play(ids: ids, shuffled: true) } label: {
                Label("Aléatoire", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .glass(14, interactive: true)
            }
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(.tint)
        .buttonStyle(.plain)
        .disabled(ids.isEmpty)
    }
}

// MARK: - Lignes de morceaux

/// Lignes de morceaux à placer dans une List : lecture, menus, balayages.
struct TrackRows: View {
    let tracks: [Track]
    var numbered = false
    var showArtwork = true
    var onDelete: ((IndexSet) -> Void)? = nil
    var onMove: ((IndexSet, Int) -> Void)? = nil
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(UIState.self) private var ui

    var body: some View {
        ForEach(tracks.indices, id: \.self) { i in
            let t = tracks[i]
            let isCurrent = t.id == player.currentID
            TrackRow(track: t, isCurrent: isCurrent,
                     number: numbered ? (t.trackNumber > 0 ? t.trackNumber : i + 1) : nil,
                     showArtwork: showArtwork)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isCurrent { ui.showPlayer = true } else { player.play(ids: tracks.map(\.id), startAt: t.id) }
                }
                .listRowBackground(isCurrent ? Color.white.opacity(0.08) : Color.clear)
                .listRowSeparatorTint(.white.opacity(0.1))
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button { player.playNext([t.id]) } label: {
                        Label("Lire ensuite", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .tint(.orange)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { ui.addToPlaylist = AddToPlaylistTarget(trackIDs: [t.id]) } label: {
                        Label("Playlist", systemImage: "text.badge.plus")
                    }
                    .tint(.indigo)
                    Button { library.toggleFavorite(t.id) } label: {
                        Label(t.isFavorite ? "Retirer" : "Favori", systemImage: t.isFavorite ? "heart.slash" : "heart")
                    }
                    .tint(.pink)
                }
                .contextMenu {
                    TrackMenuItems(track: t)
                } preview: {
                    ArtworkView(track: t, cornerRadius: 0)
                        .frame(width: 300, height: 300)
                        .environment(library)
                        .environment(settings)
                }
        }
        .onDelete(perform: onDelete)
        .onMove(perform: onMove)
    }
}

/// Actions communes à un morceau (menu contextuel).
struct TrackMenuItems: View {
    let track: Track
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(UIState.self) private var ui

    var body: some View {
        Button("Lire ensuite", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext([track.id]) }
        Button("Lire plus tard", systemImage: "text.line.last.and.arrowtriangle.forward") { player.playLater([track.id]) }
        Button("Ajouter à une playlist", systemImage: "text.badge.plus") {
            ui.addToPlaylist = AddToPlaylistTarget(trackIDs: [track.id])
        }
        Button(track.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris",
               systemImage: track.isFavorite ? "heart.slash" : "heart") {
            library.toggleFavorite(track.id)
        }
        Button("Changer la pochette", systemImage: "photo.on.rectangle") { ui.editing = EditTarget(id: track.id) }
        Button("Modifier les infos", systemImage: "pencil") { ui.editingInfo = EditTarget(id: track.id) }
        Divider()
        Button("Retirer de la bibliothèque", systemImage: "trash", role: .destructive) {
            library.remove([track.id])
            player.removed([track.id])
            library.message = "« \(track.title) » retiré"
        }
    }
}

struct TrackRow: View {
    let track: Track
    let isCurrent: Bool
    var number: Int? = nil
    var showArtwork = true
    @Environment(Player.self) private var player

    var body: some View {
        HStack(spacing: 12) {
            if let number {
                ZStack {
                    if isCurrent {
                        Image(systemName: "waveform")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tint)
                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                    } else {
                        Text("\(number)")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 26)
            }
            if showArtwork {
                ArtworkView(track: track, animated: isCurrent, small: !isCurrent, cornerRadius: 7)
                    .frame(width: 50, height: 50)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                if showArtwork || number == nil {
                    Text(track.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if track.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(.tint)
            }
            if isCurrent && number == nil {
                Image(systemName: "waveform")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Text(formatTime(track.duration))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .animation(.smooth, value: isCurrent)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? AccessibilityTraits([.isSelected, .isButton]) : AccessibilityTraits.isButton)
    }
}

extension View {
    /// Liste transparente, posée sur le fond liquide.
    func plainList() -> some View {
        self.listStyle(.plain).scrollContentBackground(.hidden)
    }
}

// MARK: - Mini-lecteur

struct MiniPlayer: View {
    var onOpen: () -> Void
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library

    var body: some View {
        if let id = player.currentID, let t = library.track(id) {
            HStack(spacing: 12) {
                ArtworkView(track: t, cornerRadius: 9)
                    .frame(width: 46, height: 46)
                    .id(t.id)
                    .transition(.opacity)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(t.displayArtist).font(.footnote).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                .id(t.id)
                .transition(.opacity)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 42, height: 42)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Lecture")
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 42, height: 42)
                }
                .accessibilityLabel("Suivant")
            }
            .buttonStyle(PressStyle())
            .foregroundStyle(.white)
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                // Fine barre de progression, comme dans Musique.
                GeometryReader { geo in
                    Capsule()
                        .fill(.white.opacity(0.7))
                        .frame(width: geo.size.width * min(1, player.currentTime / max(player.duration, 0.01)), height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 24)
                .padding(.bottom, 2)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .glass(30, interactive: true)
            .animation(.smooth(duration: 0.4), value: t.id)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAction(named: "Ouvrir le lecteur", onOpen)
        }
    }
}

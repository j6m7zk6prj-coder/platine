import SwiftUI

// MARK: - Accueil de la bibliothèque

struct LibraryHomeView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(UIState.self) private var ui

    private var currentTrack: Track? { player.currentID.flatMap { library.track($0) } }
    @State private var choosingExhibit = false

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
        .sheet(isPresented: $choosingExhibit) {
            ExhibitPicker()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                CollectionCard(choosing: $choosingExhibit)
                VStack(spacing: 0) {
                    LibraryLink(title: "Playlists", icon: "music.note.list", count: library.playlists.count) { PlaylistsView() }
                    rowDivider
                    LibraryLink(title: "Artistes", icon: "music.mic", count: library.artists.count) { ArtistsView() }
                    rowDivider
                    LibraryLink(title: "Albums", icon: "square.stack", count: library.albums.count) { AlbumsView() }
                    rowDivider
                    LibraryLink(title: "Pochettes", icon: "photo.on.rectangle.angled", count: ArtworkGalleryView.items(library).count) { ArtworkGalleryView() }
                    rowDivider
                    LibraryLink(title: "Morceaux", icon: "music.note", count: library.tracks.count) { SongsView() }
                    rowDivider
                    LibraryLink(title: "Favoris", icon: "heart", count: library.favorites.count) { SongsView(favoritesOnly: true) }
                }
                .glass(22)

                if settings.showRecent && !library.recentlyAdded.isEmpty {
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
        Divider().overlay(Color.primary.opacity(0.08)).padding(.leading, 60)
    }
}

/// La Collection en haut de la Bibliothèque : tes CD exposés, empilés, et le choix des albums à exposer.
struct CollectionCard: View {
    @Binding var choosing: Bool
    @Environment(Library.self) private var library
    @Environment(UIState.self) private var ui

    var body: some View {
        let shown = library.exposedAlbums
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Collection").font(.title2.bold())
                    Text("\(shown.count) album\(shown.count > 1 ? "s" : "") exposé\(shown.count > 1 ? "s" : "") sur \(library.albums.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choisir les albums") { choosing = true }
                    .font(.subheadline.weight(.semibold))
            }
            // Les boîtiers exposés, en pile légèrement décalée (comme sur une étagère).
            Button { ui.showShelf = true } label: {
                ZStack(alignment: .leading) {
                    if shown.isEmpty {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                            .frame(height: 96)
                            .overlay(Text("Aucun album exposé").font(.subheadline).foregroundStyle(.secondary))
                    }
                    ForEach(Array(shown.prefix(7).enumerated()), id: \.element.id) { i, album in
                        ArtworkView(track: album.cover, animated: false, small: true, cornerRadius: 3)
                            .frame(width: 96, height: 96)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.35), lineWidth: 1))
                            .shadow(color: .black.opacity(0.35), radius: 6, x: 3, y: 4)
                            .rotation3DEffect(.degrees(-18), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                            .offset(x: CGFloat(i) * 40)
                            .zIndex(Double(10 - i))
                    }
                    if !shown.isEmpty {
                        HStack {
                            Spacer()
                            Label("Ouvrir", systemImage: "chevron.right")
                                .labelStyle(.titleAndIcon)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .frame(height: 34)
                                .glassCapsule()
                        }
                    }
                }
                .frame(height: 100)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(circle: false))
            .disabled(shown.isEmpty)
        }
        .padding(16)
        .glass(22)
    }
}

/// Choisir les albums exposés dans la Collection : touche une pochette pour l'exposer ou la ranger.
struct ExhibitPicker: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        let albums = library.albums
        let count = library.exposedAlbums.count
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Touche une pochette pour l’exposer dans la Collection ou la ranger. \(count) sur \(albums.count) exposés.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("Tout exposer") { library.setAllExposed(true) }
                            .buttonStyle(.bordered)
                        Button("Tout ranger") { library.setAllExposed(false) }
                            .buttonStyle(.bordered)
                    }
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(albums) { album in
                            let on = library.isExposed(album.id)
                            Button {
                                library.setExposed(album.id, !on)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    ArtworkView(track: album.cover, animated: false, small: true, cornerRadius: 8)
                                        .aspectRatio(1, contentMode: .fit)
                                        .opacity(on ? 1 : 0.35)
                                        .saturation(on ? 1 : 0)
                                        .overlay(alignment: .topTrailing) {
                                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                                .font(.title3)
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(on ? Color.white : Color.white.opacity(0.8),
                                                                 on ? Color.accentColor : Color.black.opacity(0.3))
                                                .padding(6)
                                        }
                                    Text(album.title).font(.caption.weight(.semibold)).lineLimit(1)
                                    Text(album.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .buttonStyle(PressStyle(circle: false))
                            .sensoryFeedback(.selection, trigger: on)
                        }
                    }
                }
                .padding(18)
            }
            .navigationTitle("Albums exposés")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
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
            ArtworkView(track: album.cover, animated: false, cornerRadius: 10)
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
                .listRowBackground(isCurrent ? Color.primary.opacity(0.07) : Color.clear)
                .listRowSeparatorTint(.primary.opacity(0.1))
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
                    ArtworkView(track: t, animated: false, cornerRadius: 0)
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
                ArtworkView(track: track, animated: false, small: true, cornerRadius: 7)
                    .frame(width: 50, height: 50)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(track.title)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    if track.explicit { ExplicitBadge(size: 13) }
                }
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
    @Environment(AppSettings.self) private var settings
    @State private var dragY: CGFloat = 0

    var body: some View {
        if let id = player.currentID, let t = library.track(id) {
            HStack(spacing: 12) {
                ArtworkView(track: t, animated: false, small: true, cornerRadius: 9)
                    .frame(width: 44, height: 44)
                    .id(t.id)
                    .transition(.opacity)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.body.weight(.semibold)).lineLimit(1)
                    Text(t.displayArtist).font(.subheadline).foregroundStyle(.primary.opacity(0.75)).lineLimit(1)
                }
                .id(t.id)
                .transition(.opacity)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Lecture")
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 22))
                        .frame(width: 48, height: 44)
                }
                .accessibilityLabel("Suivant")
            }
            .buttonStyle(PressStyle())
            .foregroundStyle(.primary)
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .padding(.vertical, 9)
            .contentShape(Capsule())
            .onTapGesture(perform: onOpen)
            // Comme Musique : une pilule en Liquid Glass (verre dépoli sur les iOS plus anciens).
            .glassCapsule(interactive: true)
            .modifier(PlayerZoomSource())
            .contextMenu {
                Button(player.isPlaying ? "Pause" : "Lecture", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                    player.togglePlay()
                }
                Button("Arrêter la lecture", systemImage: "stop.fill") { player.quit() }
            }
            // Glisse le mini-lecteur vers le bas pour quitter la lecture.
            .offset(y: max(0, dragY))
            .opacity(1 - Double(min(max(0, dragY), 120)) / 160)
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        if value.translation.height > 0 { dragY = value.translation.height }
                    }
                    .onEnded { value in
                        if value.translation.height > 70 || value.predictedEndTranslation.height > 180 {
                            withAnimation(.smooth(duration: 0.3)) { dragY = 160 }
                            player.quit()
                        }
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.3)) { dragY = 0 }
                    }
            )
            .sensoryFeedback(trigger: player.currentID == nil) { _, stopped in
                stopped && settings.haptics ? .impact(weight: .light) : nil
            }
            .animation(.smooth(duration: 0.4), value: t.id)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAction(named: "Ouvrir le lecteur", onOpen)
            .accessibilityAction(named: "Arrêter la lecture") { player.quit() }
        }
    }
}

import SwiftUI

// MARK: - Accueil de la bibliothèque

struct LibraryHomeView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(UIState.self) private var ui
    @State private var showWifi = false
    @State private var showSearch = false
    @State private var route: Route?
    enum Route: Hashable, Identifiable { case artists, playlists, songs, favorites; var id: Self { self } }
    /// Taille de la grille : 2 grandes pochettes ou 3 plus petites par ligne.
    @AppStorage("libraryColumns") private var columns = 2
    @AppStorage("librarySort") private var sort = "recent"

    private var currentTrack: Track? { player.currentID.flatMap { library.track($0) } }

    private var albums: [AlbumInfo] {
        switch sort {
        case "title": return library.albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case "artist": return library.albums.sorted { ($0.artist, $0.title) < ($1.artist, $1.title) }
        default: return library.albums.sorted { $0.latestAdd > $1.latestAdd }
        }
    }

    var body: some View {
        Group {
            if library.tracks.isEmpty {
                EmptyLibraryView()
            } else {
                grid
            }
        }
        .navigationTitle("Bibliothèque")
        .navigationDestination(isPresented: $showWifi) { WifiTransferView() }
        .navigationDestination(isPresented: $showSearch) { SearchView() }
        .navigationDestination(item: $route) { r in
            switch r {
            case .artists: ArtistsView()
            case .playlists: PlaylistsView()
            case .songs: SongsView()
            case .favorites: SongsView(favoritesOnly: true)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Rechercher")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        Button("Artistes", systemImage: "music.mic") { route = .artists }
                        Button("Playlists", systemImage: "music.note.list") { route = .playlists }
                        Button("Morceaux", systemImage: "music.note") { route = .songs }
                        Button("Favoris", systemImage: "heart") { route = .favorites }
                    }
                    Section("Affichage") {
                        Picker("Taille", selection: $columns) {
                            Label("2 colonnes", systemImage: "square.grid.2x2").tag(2)
                            Label("3 colonnes", systemImage: "square.grid.3x3").tag(3)
                        }
                        Picker("Trier", selection: $sort) {
                            Text("Ajouts récents").tag("recent")
                            Text("Titre").tag("title")
                            Text("Artiste").tag("artist")
                        }
                    }
                    Section("Importer") {
                        Button("Depuis Fichiers", systemImage: "folder") { ui.importing = true }
                        Button("Par Wi‑Fi depuis le PC", systemImage: "wifi") { showWifi = true }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Plus")
            }
        }
        .background { AmbientBackground(track: currentTrack, dim: 0.55) }
    }

    /// Toutes les pochettes, en grille, comme un bac à disques.
    private var grid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: columns == 2 ? 16 : 12), count: columns)
        return ScrollView {
            LazyVGrid(columns: cols, spacing: columns == 2 ? 22 : 16) {
                ForEach(albums) { album in
                    NavigationLink { AlbumDetailView(albumID: album.id) } label: {
                        AlbumCard(album: album, compact: columns == 3)
                    }
                    .buttonStyle(PressStyle(circle: false))
                    .contextMenu { AlbumMenuItems(album: album) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .animation(.spring(response: 0.4, dampingFraction: 0.86), value: columns)
            .animation(.spring(response: 0.4, dampingFraction: 0.86), value: sort)
        }
        .scrollIndicators(.hidden)
    }
}

/// L'appui long sur une pochette : lire, mélanger, ajouter à la file.
struct AlbumMenuItems: View {
    let album: AlbumInfo
    @Environment(Player.self) private var player

    var body: some View {
        Button("Lire", systemImage: "play") { player.play(ids: album.tracks.map(\.id), shuffled: false) }
        Button("Aléatoire", systemImage: "shuffle") { player.play(ids: album.tracks.map(\.id), shuffled: true) }
        Button("Lire ensuite", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(album.tracks.map(\.id)) }
        Button("Ajouter à la file", systemImage: "text.line.last.and.arrowtriangle.forward") { player.playLater(album.tracks.map(\.id)) }
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

/// Une rubrique de la Bibliothèque : icône colorée, titre, chevron (comme dans Musique).
struct LibraryLink<Destination: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                Text(title).font(.title3)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
    }
}

/// Toucher une ligne : léger voile, comme une cellule de liste iOS.
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Color.primary.opacity(configuration.isPressed ? 0.06 : 0)
                    .padding(.horizontal, -20)
            }
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.25), value: configuration.isPressed)
    }
}

struct AlbumCard: View {
    let album: AlbumInfo
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            ArtworkView(track: album.cover, animated: true, cornerRadius: compact ? 8 : 10)
                .aspectRatio(1, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.22), radius: 12, y: 7)
                .padding(.bottom, 2)
            Text(album.title).font(compact ? .caption.weight(.medium) : .subheadline.weight(.medium)).lineLimit(1)
            Text(album.artist).font(compact ? .caption : .subheadline).foregroundStyle(.secondary).lineLimit(1)
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
    var zoomID = "miniPlayer-0"
    var onOpen: () -> Void
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var dragY: CGFloat = 0
    /// Glisser la pilule à gauche ou à droite : morceau suivant ou précédent.
    @State private var dragX: CGFloat = 0
    @State private var skipped = 0

    var body: some View {
        let t = player.currentID.flatMap { library.track($0) }
        HStack(spacing: 12) {
            // Pochette en carré arrondi, assez petite pour rester bien dans l'arrondi de la pilule.
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.12))
                if let t {
                    ArtworkView(track: t, animated: false, small: true, cornerRadius: 8, bordered: false)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .id(t?.id)
            .transition(.opacity)

            VStack(alignment: .leading, spacing: 1) {
                Text(t?.title ?? "À l’arrêt").font(.body.weight(.semibold)).lineLimit(1)
                if let t {
                    Text(t.displayArtist).font(.subheadline).foregroundStyle(.primary.opacity(0.7)).lineLimit(1)
                }
            }
            .id(t?.id)
            .transition(.opacity)
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(x: dragX)
            .opacity(1 - Double(min(abs(dragX), 80)) / 160)

            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
            }
            .disabled(t == nil)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Lecture")
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 20))
                    .frame(width: 40, height: 40)
            }
            .disabled(t == nil)
            .accessibilityLabel("Suivant")
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(.primary)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .contentShape(Capsule())
        .onTapGesture { if t != nil { onOpen() } }
        // Comme Musique : une pilule en Liquid Glass. Le lecteur sort d'elle et s'y referme.
        .glassCapsule(interactive: true)
        .modifier(PlayerZoomSource(id: zoomID))
        .contextMenu {
            if t != nil {
                Button(player.isPlaying ? "Pause" : "Lecture", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                    player.togglePlay()
                }
                Button("Suivant", systemImage: "forward.fill") { player.next() }
                Button("Précédent", systemImage: "backward.fill") { player.previous() }
                Button("Arrêter la lecture", systemImage: "stop.fill") { player.quit() }
            }
        }
        // Toute la pilule suit le doigt vers le bas ; assez loin, elle part et le son s'arrête.
        .offset(y: dragY)
        .scaleEffect(1 - min(dragY, 120) / 900, anchor: .bottom)
        .opacity(1 - Double(min(dragY, 120)) / 170)
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { g in
                    guard t != nil else { return }
                    if abs(g.translation.width) > abs(g.translation.height) {
                        dragX = g.translation.width * 0.45
                        return
                    }
                    guard g.translation.height > 0 else { return }
                    // Un peu de résistance, comme un élastique.
                    dragY = g.translation.height * (1 - min(g.translation.height, 200) / 600)
                }
                .onEnded { g in
                    guard t != nil else { return }
                    if dragX != 0 {
                        let w = g.translation.width, fling = g.predictedEndTranslation.width
                        if w < -60 || fling < -180 { player.next(); skipped += 1 }
                        else if w > 60 || fling > 180 { player.previous(); skipped += 1 }
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { dragX = 0 }
                        return
                    }
                    if g.translation.height > 60 || g.predictedEndTranslation.height > 160 {
                        withAnimation(.smooth(duration: 0.28)) { dragY = 140 }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(240))
                            player.quit()
                            // La pilule « À l'arrêt » remonte en douceur.
                            dragY = 60
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { dragY = 0 }
                        }
                    } else {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) { dragY = 0 }
                    }
                }
        )
        .sensoryFeedback(trigger: skipped) { _, _ in settings.haptics ? .selection : nil }
        .sensoryFeedback(trigger: player.currentID == nil) { _, stopped in
            stopped && settings.haptics ? .impact(weight: .medium) : nil
        }
        .animation(.smooth(duration: 0.35), value: t?.id)
        .accessibilityAction(named: "Ouvrir le lecteur", onOpen)
    }
}

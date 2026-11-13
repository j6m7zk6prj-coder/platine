import SwiftUI
import MediaPlayer

// MARK: - iPhone 8 : interface inspirée de Decoupled
// Deux écrans principaux comme Decoupled (Bibliothèque et Lecture), plus Découvrir.
// Blanc ou noir selon l'iPhone, listes simples, Cover Flow des ajouts récents,
// fiche d'album qui sort de sa pochette, file d'attente en glissant vers le haut.

// MARK: Bibliothèque

struct DecoupledLibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var ui: UIState
    @State private var query = ""
    @State private var opened: AlbumInfo?
    @State private var showSettings = false
    @State private var showWifi = false
    @Namespace private var cards

    var body: some View {
        ZStack {
            NavigationStack {
                List {
                    if !query.isEmpty {
                        searchResults
                    } else if library.tracks.isEmpty {
                        Section {
                            EmptyLibraryView()
                                .frame(minHeight: 420)
                                .listRowBackground(Color.clear)
                        }
                    } else {
                        Section {
                            CoverFlow(albums: library.recentlyAdded, namespace: cards, hidden: opened?.id) { album in
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { opened = album }
                            }
                            .frame(height: 230)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        } header: {
                            header("Récemment ajoutés")
                        }

                        Section {
                            row("Albums", library.albums.count) { AlbumsView() }
                            row("Artistes", library.artists.count) { ArtistsView() }
                            row("Morceaux", library.tracks.count) { SongsView() }
                            row("Playlists", library.playlists.count) { PlaylistsView() }
                            row("Favoris", library.favorites.count) { SongsView(favoritesOnly: true) }
                            row("Pochettes", nil) { ArtworkGalleryView() }
                            row("Clips vidéo", nil) { ClipsView() }
                        } header: {
                            header("Bibliothèque")
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $query, prompt: "Rechercher")
                .navigationTitle("Musique")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { ui.importing = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Importer")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button { showWifi = true } label: { Label("Envoi par Wi‑Fi", systemImage: "wifi") }
                            Button { showSettings = true } label: { Label("Réglages", systemImage: "gearshape") }
                        } label: {
                            Text("Fichiers")
                        }
                    }
                }
                .navigationDestination(isPresented: $showWifi) { WifiTransferView() }
                .sheet(isPresented: $showSettings) {
                    NavigationStack { SettingsView() }
                }
            }

            // La fiche d'album, sortie de sa pochette, au-dessus de tout (comme Decoupled).
            if let album = opened {
                AlbumCardOverlay(album: album, namespace: cards) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { opened = nil }
                }
                .zIndex(2)
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.title2.bold())
            .foregroundStyle(.primary)
            .textCase(nil)
            .padding(.top, 6)
    }

    private func row<D: View>(_ title: String, _ count: Int?, @ViewBuilder _ dest: @escaping () -> D) -> some View {
        NavigationLink(destination: dest) {
            HStack {
                Text(title).font(.body.weight(.semibold))
                Spacer()
                if let count { Text("\(count)").foregroundStyle(.secondary) }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private var searchResults: some View {
        let albums = library.albums.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) }
        let songs = library.tracks.filter { $0.matches(query) }
        if !albums.isEmpty {
            Section { ForEach(albums.prefix(20)) { a in
                Button { withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { opened = a } } label: {
                    HStack(spacing: 12) {
                        ArtworkView(track: a.cover, animated: false, small: true, cornerRadius: 4)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading) {
                            Text(a.title).lineLimit(1)
                            Text(a.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .foregroundStyle(.primary)
            } } header: { header("Albums") }
        }
        if !songs.isEmpty {
            Section { TrackRows(tracks: Array(songs.prefix(50)), numbered: false, showArtwork: true) } header: { header("Morceaux") }
        }
        if albums.isEmpty && songs.isEmpty {
            Text("Aucun résultat").foregroundStyle(.secondary).listRowBackground(Color.clear)
        }
    }
}

// MARK: Cover Flow

/// Les pochettes en éventail : celle du milieu face à toi, les autres tournées et empilées sur les côtés.
struct CoverFlow: View {
    let albums: [AlbumInfo]
    let namespace: Namespace.ID
    var hidden: String?
    var onOpen: (AlbumInfo) -> Void
    @State private var position: CGFloat = 0
    @GestureState private var drag: CGFloat = 0

    private let side: CGFloat = 170
    private let spacing: CGFloat = 46

    var body: some View {
        GeometryReader { geo in
            let center = geo.size.width / 2
            let current = position - drag / spacing
            ZStack {
                ForEach(Array(albums.enumerated()), id: \.element.id) { i, album in
                    let d = CGFloat(i) - current
                    let clamped = max(-1, min(1, d))
                    let x = d * spacing + clamped * (side * 0.62)
                    if abs(d) < 7 {
                        VStack(alignment: .leading, spacing: 3) {
                            cover(album)
                            if abs(d) < 0.5 {
                                Text(album.title).font(.caption.weight(.semibold)).lineLimit(1)
                                Text(album.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(width: side)
                        .rotation3DEffect(.degrees(Double(-clamped) * 58), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                        .scaleEffect(1 - abs(clamped) * 0.08)
                        .offset(x: x)
                        .position(x: center, y: geo.size.height / 2)
                        .zIndex(-Double(abs(d)))
                        .onTapGesture {
                            if abs(d) < 0.5 { onOpen(album) } else {
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { position = CGFloat(i) }
                            }
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .updating($drag) { g, s, _ in
                        if abs(g.translation.width) > abs(g.translation.height) { s = g.translation.width }
                    }
                    .onEnded { g in
                        guard abs(g.translation.width) > abs(g.translation.height) else { return }
                        let target = position - g.predictedEndTranslation.width / spacing
                        let snapped = min(CGFloat(max(0, albums.count - 1)), max(0, target.rounded()))
                        position -= g.translation.width / spacing
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { position = snapped }
                    }
            )
        }
    }

    @ViewBuilder private func cover(_ album: AlbumInfo) -> some View {
        ArtworkView(track: album.cover, animated: false, small: true, cornerRadius: 2, bordered: false)
            .frame(width: side, height: side)
            .matchedGeometryEffect(id: album.id, in: namespace, isSource: hidden != album.id)
            .opacity(hidden == album.id ? 0 : 1)
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            // Le reflet au sol, comme le Cover Flow d'origine.
            .background(alignment: .bottom) {
                ArtworkView(track: album.cover, animated: false, small: true, cornerRadius: 2, bordered: false)
                    .frame(width: side, height: side)
                    .scaleEffect(y: -1)
                    .offset(y: side + 2)
                    .mask(LinearGradient(colors: [.black.opacity(0.25), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)))
                    .opacity(hidden == album.id ? 0 : 1)
            }
    }
}

// MARK: La fiche d'album

struct AlbumCardOverlay: View {
    let album: AlbumInfo
    let namespace: Namespace.ID
    var close: () -> Void
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var ui: UIState
    @State private var appeared = false
    @State private var showAlbum = false

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.15))
                .ignoresSafeArea()
                .opacity(appeared ? 1 : 0)
                .onTapGesture(perform: close)

            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    ArtworkView(track: album.cover, cornerRadius: 4, bordered: false)
                        .aspectRatio(1, contentMode: .fit)
                        .matchedGeometryEffect(id: album.id, in: namespace)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.title).font(.headline)
                        Text(album.artist).font(.subheadline).foregroundStyle(.secondary)
                        Text("\(songCount(album.tracks.count)), \(Int((album.duration / 60).rounded())) minutes")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(format)
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.primary, in: RoundedRectangle(cornerRadius: 2))
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .padding(.top, 2)
                    }
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(spacing: 0) {
                    action("Lire") { player.play(ids: album.tracks.map(\.id)); close() }
                    Divider()
                    action("Ajouter à la file d’attente") { player.playLater(album.tracks.map(\.id)); close() }
                    Divider()
                    action("Voir l’album") { showAlbum = true }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 30)
            }
            .padding(.horizontal, 26)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.3)) { appeared = true } }
        .sheet(isPresented: $showAlbum) {
            NavigationStack { AlbumDetailView(albumID: album.id) }
        }
    }

    private var format: String {
        let ext = library.audioURL(album.first).pathExtension.uppercased()
        return ext.isEmpty ? "AUDIO" : ext
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title).frame(maxWidth: .infinity).padding(.vertical, 14)
        }
        .foregroundStyle(.tint)
    }
}

// MARK: Lecture

struct DecoupledPlaybackView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var ui: UIState
    @EnvironmentObject private var settings: AppSettings
    @State private var scrubbing: Double?
    @State private var showQueue = false

    var body: some View {
        let t = player.currentID.flatMap { library.track($0) }
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer(minLength: 8)
                ArtworkView(track: t, animated: settings.animatedArtwork, cornerRadius: 6, bordered: false)
                    .frame(width: geo.size.width - 64, height: geo.size.width - 64)
                    .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
                    .scaleEffect(player.isPlaying || t == nil ? 1 : 0.86)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.isPlaying)
                    .id(t?.id)
                    .transition(.opacity)
                Spacer(minLength: 12)
                VStack(spacing: 3) {
                    Text(t?.title ?? "Rien en lecture").font(.title3.weight(.semibold)).lineLimit(1)
                    Text(t.map { [$0.displayArtist, $0.album].filter { !$0.isEmpty }.joined(separator: " — ") } ?? " ")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 24)
                progress.padding(.horizontal, 28).padding(.top, 14)
                controls.padding(.top, 10)
                VolumeSlider().frame(height: 34).padding(.horizontal, 28).padding(.top, 8)
                HStack {
                    Button { ui.lyricsOnOpen = true; ui.showPlayer = true } label: {
                        Image(systemName: "quote.bubble").font(.title3)
                    }
                    .disabled(t == nil)
                    .accessibilityLabel("Paroles")
                    Spacer()
                    Button { showQueue = true } label: {
                        VStack(spacing: 1) {
                            Image(systemName: "chevron.up").font(.caption.weight(.bold))
                            Text("File d’attente").font(.caption2)
                        }
                    }
                    Spacer()
                    Button { ui.showPlayer = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.title3)
                    }
                    .disabled(t == nil)
                    .accessibilityLabel("Plein écran")
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color(uiColor: .systemBackground))
        // Comme Decoupled : glisser vers le haut ouvre la file d'attente.
        .gesture(DragGesture(minimumDistance: 30).onEnded { g in
            if g.translation.height < -60, abs(g.translation.height) > abs(g.translation.width) { showQueue = true }
        })
        .sheet(isPresented: $showQueue) {
            NavigationStack { QueueView() }
                .environment(\.colorScheme, .dark)
                .presentationDetents([.large])
        }
    }

    private var progress: some View {
        let total = max(player.duration, 1)
        let value = scrubbing ?? player.currentTime
        return VStack(spacing: 4) {
            Slider(value: Binding(get: { value }, set: { scrubbing = $0 }), in: 0...total) { editing in
                if !editing, let s = scrubbing { player.seek(to: s); scrubbing = nil }
            }
            .tint(.primary)
            HStack {
                Text(formatDuration(value))
                Spacer()
                Text("-" + formatDuration(max(0, total - value)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 46) {
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 28)) }
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 40))
                    .frame(width: 50)
            }
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 28)) }
        }
        .foregroundStyle(.primary)
        .buttonStyle(PressStyle())
        .disabled(player.currentID == nil)
    }
}

/// Le volume de l'iPhone (le vrai curseur système, comme dans Musique).
struct VolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: .zero)
        v.showsRouteButton = true
        return v
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

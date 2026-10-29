import SwiftUI
import UniformTypeIdentifiers

/// Structure de l'app : onglets, mini-lecteur, feuilles partagées.
struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(UIState.self) private var ui
    @Environment(\.scenePhase) private var phase
    /// La Collection est chargée (cachée) peu après le lancement, pour s'ouvrir sans attendre.
    @State private var shelfMounted = false
    /// Le mini-lecteur s'agrandit en lecteur plein écran (et s'y referme en glissant vers le bas).
    @Namespace private var playerZoom

    var body: some View {
        @Bindable var ui = ui
        TabView(selection: $ui.selectedTab) {
            NavigationStack { HomeView() }
                .modifier(MiniPlayerInset())
                .tabItem { Label("Accueil", systemImage: "house.fill") }
                .tag(0)
            NavigationStack { FeedView() }
                .tabItem { Label("Découvrir", systemImage: "play.rectangle.on.rectangle.fill") }
                .tag(4)
            NavigationStack { LibraryHomeView() }
                .modifier(MiniPlayerInset())
                .tabItem { Label("Bibliothèque", systemImage: "square.stack.fill") }
                .tag(1)
            NavigationStack { SearchView() }
                .modifier(MiniPlayerInset())
                .tabItem { Label("Recherche", systemImage: "magnifyingglass") }
                .tag(2)
            NavigationStack { SettingsView() }
                .tabItem { Label("Réglages", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .overlay(alignment: .top) { Banner() }
        .modifier(PlayerPresenter(isPresented: $ui.showPlayer, namespace: playerZoom))
        .environment(\.playerZoomNamespace, playerZoom)
        .sheet(item: $ui.editing) { target in
            ArtworkEditor(trackID: target.id)
        }
        .overlay {
            if shelfMounted {
                ShelfView(visible: ui.showShelf, onClose: { ui.showShelf = false })
                    .opacity(ui.showShelf ? 1 : 0)
                    .allowsHitTesting(ui.showShelf)
                    .accessibilityHidden(!ui.showShelf)
                    .animation(.smooth(duration: 0.32), value: ui.showShelf)
            }
        }
        .onChange(of: ui.showShelf) { _, shown in
            if shown { shelfMounted = true }
        }
        .sheet(item: $ui.editingInfo) { target in
            TrackInfoEditor(trackID: target.id)
        }
        .sheet(item: $ui.addToPlaylist) { target in
            AddToPlaylistSheet(target: target)
        }
        .fileImporter(isPresented: $ui.importing, allowedContentTypes: [.audio, .lrc], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await library.importFiles(urls) }
            }
        }
        .task {
            if settings.autoImport { await library.scanInbox() }
            // La Collection 3D est préparée en douce : elle s'ouvrira instantanément.
            try? await Task.sleep(for: .seconds(1.5))
            let playing = player.currentID.flatMap { library.track($0) }?.albumKey
            let start = library.albums.firstIndex { $0.id == playing } ?? 0
            await ShelfSceneController.warmUp(library: library, settings: settings, start: start)
            shelfMounted = true
            // Les pochettes animées de l'écran verrouillé sont préparées pendant que l'app est ouverte
            // (iOS ne permet pas de le faire une fois l'iPhone verrouillé).
            // Seulement les 4 pochettes animées écoutées le plus récemment, et après un moment :
            // l'encodage vidéo est lourd, il ne doit jamais ralentir l'app (Mode voyage prépare tout le reste).
            if settings.lockScreenAnimation {
                try? await Task.sleep(for: .seconds(20))
                let recent = library.tracks
                    .filter { library.motion($0) != nil }
                    .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
                    .prefix(4)
                for t in recent {
                    if let m = library.motion(t) {
                        LockScreenArtwork.shared.warm(source: m.url, kind: m.kind)
                    }
                }
            }
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .active, settings.autoImport { Task { await library.scanInbox() } }
        }
        .onChange(of: library.artworkRevision) { _, _ in
            player.updateNowPlaying()
        }
    }
}

/// Place le mini-lecteur au-dessus de la barre d'onglets.
struct MiniPlayerInset: ViewModifier {
    @Environment(UIState.self) private var ui
    @Environment(Player.self) private var player

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            MiniPlayer { ui.showPlayer = true }
                .animation(.spring(response: 0.5, dampingFraction: 0.82), value: player.currentID)
        }
    }
}

/// Bandeau de confirmation en haut de l'écran.
struct Banner: View {
    @Environment(Library.self) private var library

    var body: some View {
        Group {
            if library.isImporting {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Import en cours…").font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .glassCapsule()
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if let message = library.message {
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .glassCapsule()
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        if library.message == message { library.message = nil }
                    }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: library.message)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: library.isImporting)
        .allowsHitTesting(false)
    }
}


// MARK: - Ouverture du lecteur façon Musique

private struct PlayerZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var playerZoomNamespace: Namespace.ID? {
        get { self[PlayerZoomNamespaceKey.self] }
        set { self[PlayerZoomNamespaceKey.self] = newValue }
    }
}

/// Le mini-lecteur sert de point de départ : le lecteur en sort en s'agrandissant.
struct PlayerZoomSource: ViewModifier {
    @Environment(\.playerZoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let namespace {
            content.matchedTransitionSource(id: "miniPlayer", in: namespace)
        } else {
            content
        }
    }
}

/// iOS 18 et plus : le lecteur sort du mini-lecteur et y rentre quand tu le glisses vers le bas,
/// en suivant ton doigt (comme Musique). Avant iOS 18 : feuille classique.
struct PlayerPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        // Style iOS classique : le lecteur monte comme une carte, l'écran derrière recule un peu.
        content.sheet(isPresented: $isPresented) {
            NowPlayingView()
                .overlay(alignment: .top) { Grabber() }
                .presentationDragIndicator(.hidden)
                .presentationBackground(Color(.systemBackground))
        }
    }
}

/// La petite barre en haut du lecteur : on le referme en glissant vers le bas.
struct Grabber: View {
    var body: some View {
        Capsule()
            .fill(Color(.tertiaryLabel))
            .frame(width: 38, height: 5)
            .padding(.top, 8)
            .allowsHitTesting(false)
    }
}

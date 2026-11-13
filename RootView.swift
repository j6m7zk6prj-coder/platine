import SwiftUI
import UniformTypeIdentifiers

/// Structure de l'app : onglets, mini-lecteur, feuilles partagées.
struct RootView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: UIState
    @Environment(\.scenePhase) private var phase
    /// Le mini-lecteur s'agrandit en lecteur plein écran (et s'y referme en glissant vers le bas).
    @Namespace private var playerZoom

    var body: some View {
        tabs(selection: $ui.selectedTab)
        .overlay(alignment: .top) { Banner() }
        .modifier(PlayerPresenter(isPresented: $ui.showPlayer, namespace: playerZoom, sourceID: "miniPlayer-\(ui.selectedTab)"))
        .environment(\.playerZoomNamespace, playerZoom)
        .sheet(item: $ui.editing) { target in
            ArtworkEditor(trackID: target.id)
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
            // En arrière-plan : les paroles, l'album et la pochette qui manquent encore.
            Task { await TrackEnricher.fillLibrary(library) }
            // Les pochettes animées de l'écran verrouillé sont préparées pendant que l'app est ouverte
            // (iOS ne permet pas de le faire une fois l'iPhone verrouillé).
            // Seulement les 4 pochettes animées écoutées le plus récemment, et après un moment :
            // l'encodage vidéo est lourd, il ne doit jamais ralentir l'app (Mode voyage prépare tout le reste).
            if settings.lockScreenAnimation {
                try? await Task.sleep(for: .seconds(6))
                player.warmUpcomingLockArtwork()
                let recent = library.tracks
                    .filter { library.motion($0) != nil }
                    .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
                    .prefix(12)
                for t in recent {
                    if let m = library.motion(t) {
                        LockScreenArtwork.shared.warm(source: m.url, kind: m.kind)
                    }
                }
            }
        }
        .onChangeCompat(of: phase) { _, newPhase in
            if newPhase == .active, settings.autoImport { Task { await library.scanInbox() } }
            // De retour dans l'app : on prépare les pochettes animées de l'écran verrouillé qui manquent.
            if newPhase == .active { player.warmUpcomingLockArtwork() }
        }
        .onChangeCompat(of: library.artworkRevision) { _, _ in
            player.updateNowPlaying()
        }
    }
}

extension RootView {
    /// iOS 26 et plus : la barre d'onglets en Liquid Glass de Musique — elle se rétracte quand on fait défiler,
    /// le mini-lecteur vit juste au-dessus (et se loge dedans quand elle est rétractée), Recherche est à part.
    @ViewBuilder func tabs(selection: Binding<Int>) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            TabView(selection: selection) {
                Tab("Accueil", systemImage: "house.fill", value: 0) {
                    NavigationStack { HomeView() }.modifier(MiniPlayerInset(tab: 0))
                }
                Tab("Découvrir", systemImage: "play.rectangle.on.rectangle.fill", value: 4) {
                    NavigationStack { FeedView() }
                }
                Tab("Bibliothèque", systemImage: "square.stack.fill", value: 1) {
                    NavigationStack { LibraryHomeView() }.modifier(MiniPlayerInset(tab: 1))
                }
                Tab(value: 2, role: .search) {
                    NavigationStack { SearchView() }.modifier(MiniPlayerInset(tab: 2))
                }
            }
            // La pilule est notre propre mini-lecteur (au-dessus de la barre d'onglets) :
            // on peut la faire glisser en entier, et le lecteur s'y referme en se réduisant.
        } else {
            legacyTabs(selection: selection)
        }
        #else
        legacyTabs(selection: selection)
        #endif
    }

    @ViewBuilder func legacyTabs(selection: Binding<Int>) -> some View {
        TabView(selection: selection) {
            NavigationStack { HomeView() }
                .modifier(MiniPlayerInset(tab: 0))
                .tabItem { Label("Accueil", systemImage: "house.fill") }
                .tag(0)
            NavigationStack { FeedView() }
                .tabItem { Label("Découvrir", systemImage: "play.rectangle.on.rectangle.fill") }
                .tag(4)
            NavigationStack { LibraryHomeView() }
                .modifier(MiniPlayerInset(tab: 1))
                .tabItem { Label("Bibliothèque", systemImage: "square.stack.fill") }
                .tag(1)
            NavigationStack { SearchView() }
                .modifier(MiniPlayerInset(tab: 2))
                .tabItem { Label("Recherche", systemImage: "magnifyingglass") }
                .tag(2)
        }
    }
}

#if compiler(>=6.2)
/// Le mini-lecteur de Musique sur iOS 26 : il est posé sur la barre d'onglets (le verre est fourni par iOS).
/// Barre rétractée : il se réduit à la pochette, au titre et à Lecture.
@available(iOS 26.0, *)
struct AccessoryPlayer: View {
    var onOpen: () -> Void
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @State private var dragY: CGFloat = 0

    var body: some View {
        let t = player.currentID.flatMap { library.track($0) }
        let inline = placement == .inline
        HStack(spacing: 10) {
            // Pochette en carré arrondi, comme Musique : assez petite et assez loin du bord
            // pour rester entièrement à l'intérieur de la pilule (rien ne dépasse du verre).
            let side: CGFloat = inline ? 24 : 30
            let corner: CGFloat = inline ? 6 : 7
            ZStack {
                RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Color.white.opacity(0.12))
                if let t {
                    ArtworkView(track: t, animated: false, small: true, cornerRadius: corner, bordered: false)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.42, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .id(t?.id)
            VStack(alignment: .leading, spacing: 0) {
                Text(t?.title ?? "À l’arrêt").font(.subheadline.weight(.semibold)).lineLimit(1)
                if !inline, let t {
                    Text(t.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 19))
                    .contentTransition(.opacity)
                    .frame(width: 36, height: 36)
            }
            .disabled(t == nil)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Lecture")
            if !inline {
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 17))
                        .frame(width: 36, height: 36)
                }
                .disabled(t == nil)
                .accessibilityLabel("Suivant")
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, inline ? 10 : 12)
        .padding(.trailing, 10)
        .contentShape(Rectangle())
        .onTapGesture { if t != nil { onOpen() } }
        .modifier(PlayerZoomSource())
        // Glisse la pilule vers le bas : la lecture s'arrête (comme le mini-lecteur d'avant).
        .offset(y: dragY)
        .opacity(1 - Double(min(dragY, 60)) / 90)
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { g in
                    guard t != nil, g.translation.height > 0, abs(g.translation.height) > abs(g.translation.width) else { return }
                    dragY = min(g.translation.height * 0.6, 40)
                }
                .onEnded { g in
                    if t != nil, g.translation.height > 35 || g.predictedEndTranslation.height > 120 {
                        player.quit()
                    }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragY = 0 }
                }
        )
        .haptic(trigger: player.currentID == nil) { _, stopped in
            stopped && settings.haptics ? .impact(weight: .medium) : nil
        }
        .animation(.easeInOut(duration: 0.3), value: t?.id)
    }
}
#endif

/// Place le mini-lecteur au-dessus de la barre d'onglets.
struct MiniPlayerInset: ViewModifier {
    var tab = 0
    @EnvironmentObject private var ui: UIState
    @EnvironmentObject private var player: Player

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            MiniPlayer(zoomID: "miniPlayer-\(tab)") { ui.showPlayer = true }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .animation(.spring(response: 0.5, dampingFraction: 0.82), value: player.currentID)
        }
    }
}

/// Bandeau de confirmation en haut de l'écran.
struct Banner: View {
    @EnvironmentObject private var library: Library

    var body: some View {
        Group {
            if library.isImporting {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
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
    var id = "miniPlayer-0"
    @Environment(\.playerZoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let namespace {
            content.matchedTransitionSource(id: id, in: namespace) { source in
                source.clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
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
    /// La pilule de l'onglet affiché : le lecteur en sort et s'y referme.
    var sourceID = "miniPlayer-0"

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.fullScreenCover(isPresented: $isPresented) {
                NowPlayingView()
                    .environment(\.colorScheme, .dark)
                    .overlay(alignment: .top) { Grabber() }
                    .navigationTransition(.zoom(sourceID: sourceID, in: namespace))
            }
        } else {
            content.sheet(isPresented: $isPresented) {
                NowPlayingView()
                    .environment(\.colorScheme, .dark)
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(40)
                    .presentationBackground(.black)
            }
        }
    }
}

/// La petite barre en haut du lecteur : on le referme en glissant vers le bas.
struct Grabber: View {
    var body: some View {
        Capsule()
            .fill(.white.opacity(0.4))
            .frame(width: 38, height: 5)
            .padding(.top, 8)
            .allowsHitTesting(false)
    }
}

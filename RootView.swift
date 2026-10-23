import SwiftUI
import UniformTypeIdentifiers

/// Structure de l'app : onglets, mini-lecteur, feuilles partagées.
struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(UIState.self) private var ui
    @Environment(\.scenePhase) private var phase

    var body: some View {
        @Bindable var ui = ui
        TabView(selection: $ui.selectedTab) {
            NavigationStack { LibraryHomeView() }
                .modifier(MiniPlayerInset())
                .tabItem { Label("Bibliothèque", systemImage: "square.stack.fill") }
                .tag(0)
            NavigationStack { SearchView() }
                .modifier(MiniPlayerInset())
                .tabItem { Label("Recherche", systemImage: "magnifyingglass") }
                .tag(1)
            NavigationStack { SettingsView() }
                .tabItem { Label("Réglages", systemImage: "gearshape.fill") }
                .tag(2)
        }
        .overlay(alignment: .top) { Banner() }
        .sheet(isPresented: $ui.showPlayer) {
            NowPlayingView()
                .environment(\.colorScheme, .dark)
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(40)
                .presentationBackground(.black)
        }
        .sheet(item: $ui.editing) { target in
            ArtworkEditor(trackID: target.id)
        }
        .fullScreenCover(isPresented: $ui.showShelf) {
            ShelfView()
                .environment(\.colorScheme, .dark)
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
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
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

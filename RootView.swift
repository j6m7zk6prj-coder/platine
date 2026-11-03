import SwiftUI
import UniformTypeIdentifiers

/// Les onglets, comme Musique sur iOS 16 : Écouter, Bibliothèque, Recherche, avec le mini-lecteur au-dessus.
struct RootView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: UIState
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView(selection: $ui.selectedTab) {
            tab { ListenNowView() }
                .tabItem { Label("Écouter", systemImage: "play.circle.fill") }
                .tag(0)
            tab { LibraryHomeView() }
                .tabItem { Label("Bibliothèque", systemImage: "square.stack.fill") }
                .tag(1)
            tab { SearchView() }
                .tabItem { Label("Recherche", systemImage: "magnifyingglass") }
                .tag(2)
        }
        .overlay(alignment: .top) { Banner() }
        .fullScreenCover(isPresented: $ui.showPlayer) { NowPlayingView() }
        .sheet(item: $ui.editingInfo) { TrackInfoEditor(trackID: $0.id) }
        .sheet(item: $ui.addToPlaylist) { AddToPlaylistSheet(target: $0) }
        .fileImporter(isPresented: $ui.importing, allowedContentTypes: [.audio, .lrc], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await library.importFiles(urls) }
            }
        }
        .task {
            if settings.autoImport { await library.scanInbox() }
        }
        .onChange(of: phase) { newPhase in
            if newPhase == .active, settings.autoImport { Task { await library.scanInbox() } }
        }
        .onChange(of: library.artworkRevision) { _ in player.updateNowPlaying() }
    }

    /// Chaque onglet a sa navigation, et garde la place du mini-lecteur en bas.
    private func tab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack { content() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MiniPlayer { ui.showPlayer = true }
            }
    }
}

/// Le mini-lecteur au-dessus des onglets : pochette, titre, lecture et suivant (« À l'arrêt » sinon).
struct MiniPlayer: View {
    var onOpen: () -> Void
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player

    var body: some View {
        let t = player.currentID.flatMap { library.track($0) }
        HStack(spacing: 14) {
            Artwork(track: t, cornerRadius: 4, pixels: 120)
                .frame(width: 48, height: 48)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            Text(t?.title ?? "À l’arrêt")
                .font(.body)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 40, height: 44)
            }
            .disabled(t == nil)
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .frame(width: 40, height: 44)
            }
            .disabled(t == nil)
        }
        .foregroundColor(.primary)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { if t != nil { onOpen() } }
        .accessibilityElement(children: .contain)
    }
}

/// Bandeau de confirmation en haut de l'écran (import, playlist créée…).
struct Banner: View {
    @EnvironmentObject private var library: Library

    var body: some View {
        Group {
            if library.isImporting {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Import en cours…").font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if let message = library.message {
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(.regularMaterial, in: Capsule())
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

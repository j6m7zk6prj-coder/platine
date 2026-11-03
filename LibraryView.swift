import SwiftUI

// MARK: - Bibliothèque (comme Musique sur iOS 16)

struct LibraryHomeView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var ui: UIState

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Les rubriques, avec leurs icônes rouges.
                VStack(spacing: 0) {
                    link("Playlists", "music.note.list") { PlaylistsView() }
                    link("Artistes", "music.mic") { ArtistsView() }
                    link("Albums", "square.stack") { AlbumsView() }
                    link("Morceaux", "music.note") { SongsView() }
                    link("Favoris", "heart") { SongsView(favoritesOnly: true) }
                }
                .padding(.bottom, 26)

                if !library.recentlyAdded.isEmpty {
                    Text("Ajouts récents")
                        .font(.title2.bold())
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(library.recentlyAdded) { a in
                            NavigationLink { AlbumDetailView(albumID: a.id) } label: { AlbumCell(album: a) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                } else {
                    EmptyLibraryView().padding(.top, 30)
                }
            }
            .padding(.bottom, 20)
        }
        .navigationTitle("Bibliothèque")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { ui.importing = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Importer de la musique")
            }
        }
    }

    private func link<D: View>(_ title: String, _ icon: String, @ViewBuilder _ destination: @escaping () -> D) -> some View {
        NavigationLink(destination: LazyView(destination)) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundColor(.music)
                        .frame(width: 30)
                    Text(title).font(.title3).foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Color(.tertiaryLabel))
                }
                .padding(.vertical, 12)
                Divider().padding(.leading, 44)
            }
            .padding(.leading, 20)
            .padding(.trailing, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// N'ouvre la page qu'au moment où on la touche (évite de tout préparer d'avance).
struct LazyView<Content: View>: View {
    let build: () -> Content
    init(_ build: @escaping () -> Content) { self.build = build }
    var body: some View { build() }
}

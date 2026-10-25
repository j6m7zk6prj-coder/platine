import SwiftUI

/// Vue principale du carrousel de la Collection (Shelf / Étagère 3D).
struct ShelfView: View {
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(Player.self) private var player
    
    @State private var selectedIndex = 0
    @State private var isDiscOut = false
    
    var body: some View {
        VStack {
            if !library.albums.isEmpty {
                let currentAlbum = library.albums[min(selectedIndex, library.albums.count - 1)]
                let format = library.format(for: currentAlbum.id)
                let badges = library.badges(for: currentAlbum.id)
                
                ZStack {
                    Shelf3DView(album: currentAlbum,
                                format: format,
                                badges: badges,
                                isPlaying: player.isPlaying && player.currentAlbumID == currentAlbum.id,
                                discOut: isDiscOut)
                        .frame(height: 380)
                        .onTapGesture {
                            withAnimation(.spring()) {
                                isDiscOut.toggle()
                            }
                        }
                }
                
                VStack(spacing: 6) {
                    Text(currentAlbum.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(currentAlbum.artist)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 16)
                
                HStack(spacing: 20) {
                    Button(action: {
                        if selectedIndex > 0 {
                            selectedIndex -= 1
                            isDiscOut = false
                        }
                    }) {
                        Image(systemName: "chevron.left.circle.fill")
                            .font(.largeTitle)
                    }
                    .disabled(selectedIndex == 0)
                    
                    Button(action: {
                        player.play(album: currentAlbum)
                    }) {
                        Image(systemName: player.isPlaying && player.currentAlbumID == currentAlbum.id ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(.tint)
                    }
                    
                    Button(action: {
                        if selectedIndex < library.albums.count - 1 {
                            selectedIndex += 1
                            isDiscOut = false
                        }
                    }) {
                        Image(systemName: "chevron.right.circle.fill")
                            .font(.largeTitle)
                    }
                    .disabled(selectedIndex >= library.albums.count - 1)
                }
                .padding(.top, 20)
            } else {
                ContentUnavailableView("Aucun album", systemImage: "music.note.house", description: Text("Ajoute de la musique pour commencer ta collection 3D."))
            }
        }
        .navigationTitle("Collection 3D")
    }
}

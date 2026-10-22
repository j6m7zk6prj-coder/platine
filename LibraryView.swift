import SwiftUI
import UniformTypeIdentifiers

/// Écran d'accueil : la bibliothèque, le mini-lecteur et les imports.
struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(\.scenePhase) private var phase
    @State private var importing = false
    @State private var showPlayer = false
    @State private var editing: EditTarget?
    @State private var query = ""

    private var currentTrack: Track? { player.currentID.flatMap { library.track($0) } }

    private var filtered: [Track] {
        guard !query.isEmpty else { return library.tracks }
        return library.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.artist.localizedCaseInsensitiveContains(query)
                || $0.album.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.tracks.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Platine")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Importer de la musique")
                }
            }
            .background { AmbientBackground(track: currentTrack, dim: 0.5) }
        }
        .safeAreaInset(edge: .bottom) {
            MiniPlayer { showPlayer = true }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .animation(.spring(response: 0.5, dampingFraction: 0.82), value: player.currentID)
        }
        .overlay(alignment: .top) { banner }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: library.message)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: library.isImporting)
        .sheet(isPresented: $showPlayer) {
            NowPlayingView()
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(40)
                .presentationBackground(.black)
        }
        .sheet(item: $editing) { target in
            ArtworkEditor(trackID: target.id)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await library.importFiles(urls) }
            }
        }
        .task { await library.scanInbox() }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .active { Task { await library.scanInbox() } }
        }
        .onChange(of: library.artworkRevision) { _, _ in
            player.updateNowPlaying()
        }
    }

    // MARK: Liste

    private var list: some View {
        List {
            ForEach(filtered) { t in
                let isCurrent = t.id == player.currentID
                TrackRow(track: t, isCurrent: isCurrent)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isCurrent { showPlayer = true } else { player.play(t.id) }
                    }
                    .listRowBackground(isCurrent ? Color.white.opacity(0.08) : Color.clear)
                    .listRowSeparatorTint(.white.opacity(0.1))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { remove(t) } label: {
                            Label("Retirer", systemImage: "trash")
                        }
                        Button { editing = EditTarget(id: t.id) } label: {
                            Label("Pochette", systemImage: "photo")
                        }
                        .tint(.indigo)
                    }
                    .contextMenu {
                        Button("Lire", systemImage: "play.fill") { player.play(t.id) }
                        Button("Changer la pochette", systemImage: "photo.on.rectangle") {
                            editing = EditTarget(id: t.id)
                        }
                        Button("Retirer de la bibliothèque", systemImage: "trash", role: .destructive) { remove(t) }
                    } preview: {
                        ArtworkView(track: t, cornerRadius: 0)
                            .frame(width: 300, height: 300)
                            .environment(library)
                    }
            }

            Text(summary)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .padding(.vertical, 8)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $query, prompt: "Titres, artistes, albums")
        .animation(.smooth, value: library.tracks.map(\.id))
    }

    private var summary: String {
        let n = library.tracks.count
        let minutes = Int((library.totalDuration / 60).rounded())
        let length = minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min" : "\(minutes) min"
        return "\(n) morceau\(n > 1 ? "x" : "") · \(length)"
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Ta bibliothèque est vide", systemImage: "music.note")
        } description: {
            Text("Importe des morceaux depuis Fichiers, ou copie-les depuis ton PC dans le dossier Platine avec l’app Appareils Apple.")
        } actions: {
            Button { importing = true } label: {
                Text("Importer de la musique")
                    .fontWeight(.semibold)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.white)
        }
    }

    // MARK: Bandeau (import, confirmations)

    @ViewBuilder private var banner: some View {
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
                    try? await Task.sleep(nanoseconds: 2_200_000_000)
                    if library.message == message { library.message = nil }
                }
        }
    }

    private func remove(_ t: Track) {
        library.remove([t.id])
        player.removed([t.id])
        library.message = "« \(t.title) » retiré"
    }
}

// MARK: - Ligne de la bibliothèque

struct TrackRow: View {
    let track: Track
    let isCurrent: Bool
    @Environment(Player.self) private var player

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: track, animated: isCurrent, small: !isCurrent, cornerRadius: 7)
                .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                Text(track.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isCurrent {
                Image(systemName: "waveform")
                    .font(.body.weight(.semibold))
                    .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Text(formatTime(track.duration))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.vertical, 2)
        .animation(.smooth, value: isCurrent)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? AccessibilityTraits([.isSelected, .isButton]) : AccessibilityTraits.isButton)
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
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .glass(30, interactive: true)
            .animation(.smooth(duration: 0.4), value: t.id)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAction(named: "Ouvrir le lecteur", onOpen)
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

/// Modifier le titre, l'artiste, l'album, le numéro, l'année et les paroles d'un morceau.
struct TrackInfoEditor: View {
    let trackID: UUID
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var number = ""
    @State private var year = ""
    @State private var lyrics = ""
    @State private var explicit = false
    @State private var loaded = false
    @State private var searching = false
    @State private var showLRCImporter = false

    var body: some View {
        NavigationStack {
            Form {
                if let t = library.track(trackID) {
                    Section {
                        HStack {
                            Spacer()
                            ArtworkView(track: t, cornerRadius: 12)
                                .frame(width: 120, height: 120)
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                Section("Morceau") {
                    TextField("Titre", text: $title)
                    TextField("Artiste", text: $artist)
                    TextField("Album", text: $album)
                    Toggle(isOn: $explicit) {
                        HStack(spacing: 8) {
                            Text("Contenu explicite")
                            ExplicitBadge()
                        }
                    }
                }
                Section("Détails") {
                    LabeledContent("N° de piste") {
                        TextField("—", text: $number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Année") {
                        TextField("—", text: $year)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Section {
                    TextEditor(text: $lyrics)
                        .font(.callout.monospaced())
                        .frame(minHeight: 180)
                    Button {
                        Task { await searchLyrics() }
                    } label: {
                        HStack {
                            Label("Chercher les paroles en ligne", systemImage: "magnifyingglass")
                            Spacer()
                            if searching { ProgressView() }
                        }
                    }
                    .disabled(searching)
                    Button {
                        showLRCImporter = true
                    } label: {
                        Label("Importer un fichier .lrc", systemImage: "doc.text")
                    }
                    if !lyrics.isEmpty {
                        Button("Effacer les paroles", role: .destructive) { lyrics = "" }
                    }
                } header: {
                    HStack {
                        Text("Paroles")
                        Spacer()
                        if LyricsParser.isSynced(lyrics) {
                            Label("Synchronisées", systemImage: "waveform")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                } footer: {
                    Text("Pour des paroles synchronisées, chaque ligne commence par son temps : [01:23.45] Texte. La recherche utilise LRCLIB, une base de paroles gratuite.")
                }
            }
            .navigationTitle("Modifier les infos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        library.updateInfo(trackID, title: title, artist: artist, album: album,
                                           trackNumber: Int(number) ?? 0, year: Int(year) ?? 0, lyrics: lyrics)
                        library.setExplicit(trackID, explicit)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .fileImporter(isPresented: $showLRCImporter, allowedContentTypes: [.lrc, .plainText]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) {
                    lyrics = text
                }
            }
            .onAppear {
                guard !loaded, let t = library.track(trackID) else { return }
                loaded = true
                title = t.title
                artist = t.artist
                album = t.album
                number = t.trackNumber > 0 ? "\(t.trackNumber)" : ""
                year = t.year > 0 ? "\(t.year)" : ""
                lyrics = t.lyrics ?? ""
                explicit = t.explicit
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func searchLyrics() async {
        searching = true
        let duration = library.track(trackID)?.duration ?? 0
        let found = await LyricsService.search(title: title, artist: artist, duration: duration)
        searching = false
        if let found {
            lyrics = found
        } else {
            library.message = "Aucune parole trouvée"
        }
    }
}

/// Photo ronde d'un artiste : celle que tu as choisie, sinon la pochette d'un de ses morceaux.
struct ArtistAvatar: View {
    let artist: ArtistInfo
    @Environment(Library.self) private var library

    var body: some View {
        Color.clear
            .overlay {
                if let img = library.artistImage(artist.id) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    ArtworkView(track: artist.tracks.first, animated: false, cornerRadius: 0)
                }
            }
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(Color(.separator), lineWidth: 0.5) }
            .accessibilityHidden(true)
    }
}

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Accueil personnalisable (comme l'écran d'accueil de l'iPhone)

/// Une rubrique de l'Accueil. Les rubriques « épinglées » montrent un artiste, une playlist ou un album précis.
struct HomeItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case resume, mixes, playlists, clips, edits, recent, added, artists, artist, playlist, album
    }

    var id = UUID()
    var kind: Kind
    /// Identifiant de l'artiste, de la playlist ou de l'album épinglé.
    var ref: String?

    var title: String {
        switch kind {
        case .resume: return "Reprendre l’écoute"
        case .mixes: return "Tes mix"
        case .playlists: return "Tes playlists"
        case .clips: return "Clips vidéo"
        case .edits: return "Edits"
        case .recent: return "Écoutés récemment"
        case .added: return "Ajouts récents"
        case .artists: return "Tes artistes"
        case .artist: return "Artiste"
        case .playlist: return "Playlist"
        case .album: return "Album"
        }
    }

    var symbol: String {
        switch kind {
        case .resume: return "play.circle.fill"
        case .mixes: return "shuffle"
        case .playlists: return "music.note.list"
        case .clips: return "film"
        case .edits: return "rectangle.portrait.on.rectangle.portrait"
        case .recent: return "clock.arrow.circlepath"
        case .added: return "plus.square.on.square"
        case .artists: return "music.mic"
        case .artist: return "person.crop.circle"
        case .playlist: return "music.note.list"
        case .album: return "square.stack"
        }
    }

    /// Rubriques qu'on ne met qu'une fois (les épinglées peuvent être plusieurs).
    var isUnique: Bool { ![.artist, .playlist, .album].contains(kind) }

    /// L'Accueil épuré : le bandeau « Reprendre l'écoute », les ajouts récents et tes playlists.
    static let defaults: [HomeItem] = [
        HomeItem(kind: .resume), HomeItem(kind: .added), HomeItem(kind: .playlists)
    ]
}

/// L'ordre des rubriques de l'Accueil et l'ordre des artistes, gardés sur l'iPhone.
@MainActor
@Observable
final class HomeLayout {
    static let shared = HomeLayout()

    private(set) var items: [HomeItem] = HomeItem.defaults {
        didSet { save() }
    }
    /// Tes artistes dans l'ordre choisi (les autres suivent, du plus écouté au moins écouté).
    private(set) var artistOrder: [String] = [] {
        didSet { UserDefaults.standard.set(artistOrder, forKey: "homeArtistOrder") }
    }
    /// Artistes cachés de la rubrique « Tes artistes ».
    private(set) var hiddenArtists: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(hiddenArtists), forKey: "homeHiddenArtists") }
    }
    /// Mode « modifier l'accueil » : les rubriques tremblent, on peut les déplacer ou les retirer.
    var editing = false

    init() {
        // Refonte 2026 : une seule fois, l'Accueil repart sur la nouvelle disposition épurée.
        if UserDefaults.standard.integer(forKey: "homeLayoutVersion") < 3 {
            UserDefaults.standard.removeObject(forKey: "homeLayout")
            UserDefaults.standard.set(3, forKey: "homeLayoutVersion")
        }
        if let data = UserDefaults.standard.data(forKey: "homeLayout"),
           let list = try? JSONDecoder().decode([HomeItem].self, from: data), !list.isEmpty {
            items = list
        }
        artistOrder = UserDefaults.standard.stringArray(forKey: "homeArtistOrder") ?? []
        hiddenArtists = Set(UserDefaults.standard.stringArray(forKey: "homeHiddenArtists") ?? [])
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: "homeLayout") }
    }

    func contains(_ kind: HomeItem.Kind) -> Bool { items.contains { $0.kind == kind } }

    func add(_ item: HomeItem, at index: Int? = nil) {
        if item.isUnique, contains(item.kind) { return }
        if item.ref != nil, items.contains(where: { $0.kind == item.kind && $0.ref == item.ref }) { return }
        if let index, items.indices.contains(index) { items.insert(item, at: index) } else { items.insert(item, at: 0) }
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    func move(_ id: UUID, by step: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let j = i + step
        guard items.indices.contains(j) else { return }
        items.swapAt(i, j)
    }

    /// Déplace une rubrique à la place d'une autre (glisser-déposer).
    func move(_ id: UUID, to target: UUID) {
        guard id != target, let from = items.firstIndex(where: { $0.id == id }),
              let to = items.firstIndex(where: { $0.id == target }) else { return }
        let item = items.remove(at: from)
        items.insert(item, at: to)
    }

    func moveItems(from: IndexSet, to: Int) { items.move(fromOffsets: from, toOffset: to) }

    func reset() {
        items = HomeItem.defaults
        artistOrder = []
        hiddenArtists = []
    }

    // MARK: Artistes

    /// Les artistes de la rubrique, dans l'ordre choisi, sans les cachés.
    func orderedArtists(_ all: [ArtistInfo]) -> [ArtistInfo] {
        func plays(_ a: ArtistInfo) -> Int { a.tracks.reduce(0) { $0 + $1.playCount } }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let first = artistOrder.compactMap { byID[$0] }
        let rest = all.filter { !artistOrder.contains($0.id) }.sorted { plays($0) > plays($1) }
        return (first + rest).filter { !hiddenArtists.contains($0.id) }
    }

    func setArtistOrder(_ ids: [String]) { artistOrder = ids }

    func setHidden(_ id: String, _ hidden: Bool) {
        if hidden { hiddenArtists.insert(id) } else { hiddenArtists.remove(id) }
    }
}

// MARK: - Rubrique en mode modification (elle tremble, comme les apps de l'écran d'accueil)

struct EditableSection<Content: View>: View {
    let item: HomeItem
    let isFirst: Bool
    let isLast: Bool
    @ViewBuilder var content: () -> Content
    @State private var wobble = false
    @State private var options = false
    private var layout: HomeLayout { .shared }

    var body: some View {
        let editing = layout.editing
        content()
            .allowsHitTesting(!editing)
            .padding(.vertical, editing ? 12 : 0)
            .background {
                if editing {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                        .padding(.horizontal, 8)
                }
            }
            .overlay(alignment: .topLeading) {
                if editing {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { layout.remove(item.id) }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(.primary)
                            .frame(width: 28, height: 28)
                            .glassCircle()
                    }
                    .offset(x: 2, y: -12)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Retirer « \(item.title) »")
                }
            }
            .overlay(alignment: .topTrailing) {
                if editing {
                    HStack(spacing: 6) {
                        if item.kind == .artists {
                            Button { options = true } label: {
                                Image(systemName: "slider.horizontal.3").frame(width: 34, height: 30).glassCapsule(interactive: true)
                            }
                            .accessibilityLabel("Choisir et ranger les artistes")
                        }
                        Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { layout.move(item.id, by: -1) } } label: {
                            Image(systemName: "chevron.up").frame(width: 34, height: 30).glassCapsule(interactive: true)
                        }
                        .disabled(isFirst)
                        .accessibilityLabel("Monter")
                        Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { layout.move(item.id, by: 1) } } label: {
                            Image(systemName: "chevron.down").frame(width: 34, height: 30).glassCapsule(interactive: true)
                        }
                        .disabled(isLast)
                        .accessibilityLabel("Descendre")
                    }
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.primary)
                    .offset(x: -14, y: -12)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            // Le petit tremblement des icônes quand on range l'écran d'accueil.
            .rotationEffect(.degrees(editing ? (wobble ? 0.45 : -0.45) : 0))
            .animation(editing ? .easeInOut(duration: 0.13).repeatForever(autoreverses: true) : .default, value: wobble)
            .onChange(of: editing, initial: true) { _, on in
                if on {
                    // Départ décalé pour que les rubriques ne tremblent pas toutes ensemble.
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0...0.12)) { wobble = true }
                } else {
                    wobble = false
                }
            }
            .modifier(DragToReorder(id: item.id, enabled: editing))
            .sheet(isPresented: $options) { ArtistOrderSheet() }
    }
}

/// Glisser une rubrique sur une autre pour la déplacer (seulement en mode modification).
private struct DragToReorder: ViewModifier {
    let id: UUID
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag { NSItemProvider(object: id.uuidString as NSString) }
                .onDrop(of: [.text], delegate: HomeDropDelegate(target: id))
        } else {
            content
        }
    }
}

private struct HomeDropDelegate: DropDelegate {
    let target: UUID

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, let id = UUID(uuidString: s) else { return }
            Task { @MainActor in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { HomeLayout.shared.move(id, to: target) }
            }
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

// MARK: - Ajouter une rubrique (la galerie, comme les widgets)

struct HomeGallery: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    private var layout: HomeLayout { .shared }

    var body: some View {
        NavigationStack {
            List {
                Section("Rubriques") {
                    ForEach(HomeItem.Kind.allCases.filter { ![.artist, .playlist, .album, .clips].contains($0) }, id: \.self) { kind in
                        let item = HomeItem(kind: kind)
                        let already = layout.contains(kind)
                        Button {
                            layout.add(item)
                            dismiss()
                        } label: {
                            row(item.title, item.symbol, detail: already ? "Déjà sur l’Accueil" : nil)
                        }
                        .disabled(already)
                    }
                }
                Section {
                    NavigationLink { PinPicker(kind: .artist) { dismiss() } } label: {
                        row("Un artiste", "person.crop.circle", detail: "Sa photo, ses albums et ses titres")
                    }
                    NavigationLink { PinPicker(kind: .playlist) { dismiss() } } label: {
                        row("Une playlist", "music.note.list", detail: "En grand, avec ses titres")
                    }
                    NavigationLink { PinPicker(kind: .album) { dismiss() } } label: {
                        row("Un album", "square.stack", detail: "Sa pochette, prête à lire")
                    }
                } header: {
                    Text("Épingler")
                } footer: {
                    Text("Tu peux en épingler autant que tu veux, puis les ranger où tu veux.")
                }
            }
            .navigationTitle("Ajouter à l’Accueil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ title: String, _ symbol: String, detail: String?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .glass(12)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Choisir l'artiste, la playlist ou l'album à épingler.
private struct PinPicker: View {
    let kind: HomeItem.Kind
    var done: () -> Void
    @Environment(Library.self) private var library
    @State private var query = ""
    private var layout: HomeLayout { .shared }

    var body: some View {
        List {
            switch kind {
            case .artist:
                ForEach(library.artists.filter { match($0.name) }) { a in
                    Button { pin(a.id) } label: {
                        HStack(spacing: 12) {
                            ArtistAvatar(artist: a).frame(width: 44, height: 44)
                            Text(a.name).foregroundStyle(.primary)
                        }
                    }
                }
            case .playlist:
                ForEach(library.sortedPlaylists.filter { match($0.name) }) { p in
                    Button { pin(p.id.uuidString) } label: {
                        HStack(spacing: 12) {
                            PlaylistMosaic(playlist: p).frame(width: 44, height: 44)
                            Text(p.name).foregroundStyle(.primary)
                        }
                    }
                }
            default:
                ForEach(library.albums.filter { match($0.title) || match($0.artist) }) { a in
                    Button { pin(a.id) } label: {
                        HStack(spacing: 12) {
                            ArtworkView(track: a.cover, animated: false, small: true, cornerRadius: 8).frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.title).foregroundStyle(.primary).lineLimit(1)
                                Text(a.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle(kind == .artist ? "Choisir un artiste" : (kind == .playlist ? "Choisir une playlist" : "Choisir un album"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func match(_ s: String) -> Bool { query.isEmpty || s.localizedCaseInsensitiveContains(query) }

    private func pin(_ ref: String) {
        layout.add(HomeItem(kind: kind, ref: ref))
        done()
    }
}

/// « Tes artistes » : lesquels montrer, et dans quel ordre.
struct ArtistOrderSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var order: [String] = []
    @State private var hidden: Set<String> = []
    private var layout: HomeLayout { .shared }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(order, id: \.self) { id in
                        if let a = library.artist(id) {
                            HStack(spacing: 12) {
                                ArtistAvatar(artist: a).frame(width: 40, height: 40)
                                Text(a.name)
                                Spacer()
                                Button {
                                    if hidden.contains(id) { hidden.remove(id) } else { hidden.insert(id) }
                                } label: {
                                    Image(systemName: hidden.contains(id) ? "eye.slash" : "eye")
                                        .foregroundStyle(hidden.contains(id) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                                }
                                .buttonStyle(.borderless)
                            }
                            .opacity(hidden.contains(id) ? 0.45 : 1)
                        }
                    }
                    .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("Glisse les artistes pour choisir leur place. L’œil cache un artiste de la rubrique (il reste dans ta bibliothèque).")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Tes artistes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        layout.setArtistOrder(order)
                        for a in library.artists { layout.setHidden(a.id, hidden.contains(a.id)) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                // Les artistes dans l'ordre actuel de l'Accueil, puis les cachés.
                let shown = layout.orderedArtists(library.artists).map(\.id)
                let rest = library.artists.map(\.id).filter { !shown.contains($0) }
                order = shown + rest
                hidden = layout.hiddenArtists
            }
        }
    }
}

/// L'Accueil en mode « tout ranger » : une liste qu'on réordonne au doigt.
struct HomeOrganizer: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    private var layout: HomeLayout { .shared }

    var body: some View {
        NavigationStack {
            List {
                ForEach(layout.items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol).foregroundStyle(.tint).frame(width: 28)
                        Text(label(item))
                    }
                }
                .onMove { layout.moveItems(from: $0, to: $1) }
                .onDelete { idx in idx.map { layout.items[$0].id }.forEach(layout.remove) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Ranger l’Accueil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() }.fontWeight(.semibold) }
                ToolbarItem(placement: .bottomBar) {
                    Button("Rétablir l’Accueil d’origine", role: .destructive) { layout.reset() }
                }
            }
        }
    }

    private func label(_ item: HomeItem) -> String {
        guard let ref = item.ref else { return item.title }
        switch item.kind {
        case .artist: return "Artiste : " + (library.artist(ref)?.name ?? "?")
        case .playlist: return "Playlist : " + (UUID(uuidString: ref).flatMap { library.playlist($0) }?.name ?? "?")
        case .album: return "Album : " + (library.album(ref)?.title ?? "?")
        default: return item.title
        }
    }
}

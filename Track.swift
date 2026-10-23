import Foundation

/// Type de pochette personnalisée.
enum ArtworkKind: String, Codable {
    case image, gif, video
}

struct Track: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var artist: String
    var album: String
    var trackNumber: Int = 0
    var year: Int = 0
    var duration: Double
    /// Nom du fichier audio dans le dossier Music interne.
    var audioFile: String
    /// Pochette trouvée dans le fichier audio (dossier Artwork interne).
    var embeddedArtwork: String?
    /// Pochette choisie dans l'app : image, GIF ou vidéo.
    var customArtwork: String?
    var customKind: ArtworkKind?
    var addedAt: Date = Date()
    var isFavorite: Bool = false
    var playCount: Int = 0
    var lastPlayed: Date?
    var lyrics: String?
    /// Jeux dont ce morceau fait partie de la bande-son (ex. « FIFA 17 », « FC 24 »).
    var games: [String] = []

    var displayArtist: String { artist.isEmpty ? "Artiste inconnu" : artist }
    var displayAlbum: String { album.isEmpty ? "Sans album" : album }

    var subtitle: String {
        [displayArtist, album].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Clé qui regroupe les morceaux d'un même album.
    var albumKey: String { displayArtist.lowercased() + "|" + displayAlbum.lowercased() }

    func matches(_ query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query)
            || artist.localizedCaseInsensitiveContains(query)
            || album.localizedCaseInsensitiveContains(query)
    }
}

// Décodage tolérant : les champs ajoutés plus tard ont une valeur par défaut.
extension Track {
    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, trackNumber, year, duration, audioFile
        case embeddedArtwork, customArtwork, customKind, addedAt
        case isFavorite, playCount, lastPlayed, lyrics, games
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        trackNumber = try c.decodeIfPresent(Int.self, forKey: .trackNumber) ?? 0
        year = try c.decodeIfPresent(Int.self, forKey: .year) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        audioFile = try c.decode(String.self, forKey: .audioFile)
        embeddedArtwork = try c.decodeIfPresent(String.self, forKey: .embeddedArtwork)
        customArtwork = try c.decodeIfPresent(String.self, forKey: .customArtwork)
        customKind = try c.decodeIfPresent(ArtworkKind.self, forKey: .customKind)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        playCount = try c.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        lastPlayed = try c.decodeIfPresent(Date.self, forKey: .lastPlayed)
        lyrics = try c.decodeIfPresent(String.self, forKey: .lyrics)
        games = try c.decodeIfPresent([String].self, forKey: .games) ?? []
    }
}

struct Playlist: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var trackIDs: [UUID] = []
    var createdAt: Date = Date()
    var pinned: Bool = false
}

struct AlbumInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let year: Int
    let tracks: [Track]
    var first: Track { tracks[0] }
    var duration: Double { tracks.reduce(0) { $0 + $1.duration } }
    var latestAdd: Date { tracks.map(\.addedAt).max() ?? .distantPast }
}

struct ArtistInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let tracks: [Track]
    let albums: [AlbumInfo]
}

/// Format physique d'un album dans la Collection.
enum AlbumFormat: String, CaseIterable, Identifiable {
    case cd, cassette, game
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cd: return "CD"
        case .cassette: return "Cassette"
        case .game: return "Jeu vidéo"
        }
    }
    /// Formats proposés pour un album (le boîtier de jeu est réservé aux bandes-son).
    static let choosable: [AlbumFormat] = [.cd, .cassette]
}

/// Les jeux de foot dont on peut taguer la bande-son.
enum GameCatalog {
    static let prefix = "game:"

    /// Du plus récent au plus ancien.
    static let all: [String] = {
        var list: [String] = ["FC 26", "FC 25", "FC 24"]
        for n in stride(from: 23, through: 6, by: -1) {
            list.append(String(format: "FIFA %02d", n))
        }
        for year in stride(from: 2005, through: 2000, by: -1) {
            list.append("FIFA " + String(year))
        }
        for n in stride(from: 99, through: 94, by: -1) {
            list.append("FIFA " + String(n))
        }
        return list
    }()

    /// Année de sortie du jeu (FIFA 17 est sorti en 2016, FC 24 en 2023).
    static func releaseYear(_ game: String) -> Int {
        let digits = game.filter(\.isNumber)
        guard let n = Int(digits) else { return 0 }
        if n >= 1000 { return n - 1 }
        if n >= 90 { return 1900 + n - 1 }
        return 2000 + n - 1
    }

    /// « Saison 2016-17 ».
    static func season(_ game: String) -> String {
        let y = releaseYear(game)
        guard y > 0 else { return "" }
        return "Saison \(y)-\(String(format: "%02d", (y + 1) % 100))"
    }
}

/// Badges holographiques gagnés par un album.
enum AlbumBadge: String, Identifiable, CaseIterable {
    // Gagnés automatiquement (si l'option est activée)
    case platinum, gold, favorite, new
    // Stickers à poser soi-même (appui long sur un album dans la Collection)
    case limited, collector, signed, remastered, explicit, star, deluxe, vinylFeel, heart, fire

    var id: String { rawValue }

    /// Les stickers proposés quand on appuie longtemps sur un album.
    static let stickers: [AlbumBadge] = [.limited, .collector, .deluxe, .signed, .remastered, .explicit,
                                         .star, .heart, .fire, .new, .gold, .platinum]

    var short: String {
        switch self {
        case .platinum: return "Platine"
        case .gold: return "Or"
        case .favorite: return "Favori"
        case .new: return "Nouveau"
        case .limited: return "Édition limitée"
        case .collector: return "Collector"
        case .signed: return "Signé"
        case .remastered: return "Remasterisé"
        case .explicit: return "Explicite"
        case .star: return "Étoile"
        case .deluxe: return "Deluxe"
        case .vinylFeel: return "Analogique"
        case .heart: return "Coup de cœur"
        case .fire: return "Classique"
        }
    }
    var label: String {
        switch self {
        case .platinum: return "Disque de platine"
        case .gold: return "Disque d’or"
        default: return short
        }
    }
    var symbol: String {
        switch self {
        case .platinum, .gold: return "opticaldisc.fill"
        case .favorite, .heart: return "heart.fill"
        case .new: return "sparkles"
        case .limited: return "seal.fill"
        case .collector: return "crown.fill"
        case .signed: return "signature"
        case .remastered: return "waveform"
        case .explicit: return "e.square.fill"
        case .star: return "star.fill"
        case .deluxe: return "diamond.fill"
        case .vinylFeel: return "record.circle"
        case .fire: return "flame.fill"
        }
    }
    /// Médaille ronde (disques, étoile, cœur), étiquette pour les autres.
    var isMedal: Bool { [.platinum, .gold, .star, .heart, .fire].contains(self) }
    /// Teinte du sticker : or, argent ou holographique arc-en-ciel.
    var isGolden: Bool { self == .gold || self == .collector || self == .deluxe }
}

/// Sert à ouvrir l'éditeur de pochette pour un morceau précis.
struct EditTarget: Identifiable {
    let id: UUID
}

/// Sert à ouvrir « Ajouter à une playlist ».
struct AddToPlaylistTarget: Identifiable {
    let id = UUID()
    let trackIDs: [UUID]
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let s = Int(seconds.rounded(.down))
    let h = s / 3600, m = (s % 3600) / 60, r = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
}

/// « 42 min » ou « 1 h 05 min ».
func formatDuration(_ seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded())
    if minutes >= 60 { return "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min" }
    return "\(minutes) min"
}

func songCount(_ n: Int) -> String { n == 1 ? "1 morceau" : "\(n) morceaux" }


/// Finition d'un sticker fait à partir de ta propre image.
enum StickerFinish: String, Codable, CaseIterable, Identifiable {
    case holo, silver, gold, rose, color
    var id: String { rawValue }
    var label: String {
        switch self {
        case .holo: return "Holographique"
        case .silver: return "Argent"
        case .gold: return "Or"
        case .rose: return "Or rose"
        case .color: return "Couleurs + reflet"
        }
    }
}

/// Sticker créé à partir d'une image (gardée dans le dossier des pochettes).
struct CustomSticker: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var file: String
    var finish: StickerFinish
    var name: String = "Mon sticker"
    /// Forme découpée : rond ou carré arrondi.
    var round: Bool = true

    static let prefix = "custom:"
    var key: String { Self.prefix + id.uuidString }
}


/// Console du boîtier de jeu : même format Blu-ray (135 × 171,5 mm), plastique et bandeau différents.
enum GamePlatform: String, Codable, CaseIterable, Identifiable {
    case ps3, ps4, ps5
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

/// Position d'un sticker sur la jaquette : x et y de 0 à 1, taille relative.
struct StickerPlacement: Codable, Hashable {
    var x: Double
    var y: Double
    var scale: Double = 1
    var rotation: Double = 0

    /// Placement par défaut : en colonne, en haut à droite.
    static func standard(_ index: Int) -> StickerPlacement {
        StickerPlacement(x: 0.84, y: 0.13 + 0.19 * Double(index), scale: 1)
    }

    var signature: String {
        String(format: "%.3f,%.3f,%.2f,%.2f", x, y, scale, rotation)
    }
}

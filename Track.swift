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
        case isFavorite, playCount, lastPlayed, lyrics
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
    case cd, cassette
    var id: String { rawValue }
    var label: String { self == .cd ? "CD" : "Cassette" }
}

/// Badges holographiques gagnés par un album.
enum AlbumBadge: String, Identifiable {
    case platinum, gold, favorite, new
    var id: String { rawValue }
    var short: String {
        switch self {
        case .platinum: return "Platine"
        case .gold: return "Or"
        case .favorite: return "Favori"
        case .new: return "Nouveau"
        }
    }
    var label: String {
        switch self {
        case .platinum: return "Disque de platine · 100 écoutes"
        case .gold: return "Disque d’or · 50 écoutes"
        case .favorite: return "Favori"
        case .new: return "Nouveau"
        }
    }
    var symbol: String {
        switch self {
        case .platinum, .gold: return "opticaldisc.fill"
        case .favorite: return "heart.fill"
        case .new: return "sparkles"
        }
    }
    /// Médaille ronde pour les disques d'or et de platine, étiquette pour les autres.
    var isMedal: Bool { self == .platinum || self == .gold }
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

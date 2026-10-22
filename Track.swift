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
    var duration: Double
    /// Nom du fichier audio dans le dossier Music interne.
    var audioFile: String
    /// Pochette trouvée dans le fichier audio (dossier Artwork interne).
    var embeddedArtwork: String?
    /// Pochette choisie dans l'app : image, GIF ou vidéo.
    var customArtwork: String?
    var customKind: ArtworkKind?
    var addedAt: Date = Date()

    var displayArtist: String { artist.isEmpty ? "Artiste inconnu" : artist }

    var subtitle: String {
        [displayArtist, album].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Sert à ouvrir l'éditeur de pochette pour un morceau précis.
struct EditTarget: Identifiable {
    let id: UUID
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let s = Int(seconds.rounded(.down))
    let h = s / 3600, m = (s % 3600) / 60, r = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
}

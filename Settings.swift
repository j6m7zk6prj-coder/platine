import SwiftUI
import Observation

enum SongSort: String, CaseIterable, Identifiable {
    case title, artist, album, recent, mostPlayed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .title: return "Titre"
        case .artist: return "Artiste"
        case .album: return "Album"
        case .recent: return "Ajouts récents"
        case .mostPlayed: return "Plus écoutés"
        }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case white, pink, orange, green, blue, purple
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .white: return .white
        case .pink: return Color(red: 1.0, green: 0.36, blue: 0.48)
        case .orange: return Color(red: 1.0, green: 0.62, blue: 0.28)
        case .green: return Color(red: 0.36, green: 0.86, blue: 0.52)
        case .blue: return Color(red: 0.38, green: 0.70, blue: 1.0)
        case .purple: return Color(red: 0.72, green: 0.56, blue: 1.0)
        }
    }
    var label: String {
        switch self {
        case .white: return "Blanc"
        case .pink: return "Rose"
        case .orange: return "Orange"
        case .green: return "Vert"
        case .blue: return "Bleu"
        case .purple: return "Violet"
        }
    }
}

/// Réglages de l'app, enregistrés sur l'iPhone.
@MainActor
@Observable
final class AppSettings {
    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    static func speedLabel(_ s: Double) -> String {
        s == 1 ? "Normale" : String(format: "%g×", s)
    }

    var fadeTransitions: Bool { didSet { UserDefaults.standard.set(fadeTransitions, forKey: "fadeTransitions") } }
    var fadeDuration: Double { didSet { UserDefaults.standard.set(fadeDuration, forKey: "fadeDuration") } }
    var playbackSpeed: Double { didSet { UserDefaults.standard.set(playbackSpeed, forKey: "playbackSpeed") } }
    var pauseOnDisconnect: Bool { didSet { UserDefaults.standard.set(pauseOnDisconnect, forKey: "pauseOnDisconnect") } }
    var animatedArtwork: Bool { didSet { UserDefaults.standard.set(animatedArtwork, forKey: "animatedArtwork") } }
    var dynamicBackground: Bool { didSet { UserDefaults.standard.set(dynamicBackground, forKey: "dynamicBackground") } }
    var haptics: Bool { didSet { UserDefaults.standard.set(haptics, forKey: "haptics") } }
    var autoImport: Bool { didSet { UserDefaults.standard.set(autoImport, forKey: "autoImport") } }
    var accent: AccentChoice { didSet { UserDefaults.standard.set(accent.rawValue, forKey: "accent") } }
    var songSort: SongSort { didSet { UserDefaults.standard.set(songSort.rawValue, forKey: "songSort") } }
    var shelfFormat: AlbumFormat { didSet { UserDefaults.standard.set(shelfFormat.rawValue, forKey: "shelfFormat") } }

    init() {
        let d = UserDefaults.standard
        fadeTransitions = d.object(forKey: "fadeTransitions") as? Bool ?? false
        fadeDuration = d.object(forKey: "fadeDuration") as? Double ?? 4
        playbackSpeed = d.object(forKey: "playbackSpeed") as? Double ?? 1
        pauseOnDisconnect = d.object(forKey: "pauseOnDisconnect") as? Bool ?? true
        animatedArtwork = d.object(forKey: "animatedArtwork") as? Bool ?? true
        dynamicBackground = d.object(forKey: "dynamicBackground") as? Bool ?? true
        haptics = d.object(forKey: "haptics") as? Bool ?? true
        autoImport = d.object(forKey: "autoImport") as? Bool ?? true
        accent = AccentChoice(rawValue: d.string(forKey: "accent") ?? "") ?? .pink
        songSort = SongSort(rawValue: d.string(forKey: "songSort") ?? "") ?? .title
        shelfFormat = AlbumFormat(rawValue: d.string(forKey: "shelfFormat") ?? "") ?? .cd
    }
}

/// État de l'interface partagé entre les écrans.
@MainActor
@Observable
final class UIState {
    var showPlayer = false
    var editing: EditTarget?
    var editingInfo: EditTarget?
    var addToPlaylist: AddToPlaylistTarget?
    var importing = false
    var showShelf = false
    var selectedTab = 0
}

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

/// Thème de l'app.
/// Mode clair ou sombre, en plus du thème choisi.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case theme, light, dark, auto
    var id: String { rawValue }
    var label: String {
        switch self {
        case .theme: return "Thème"
        case .light: return "Clair"
        case .dark: return "Sombre"
        case .auto: return "Auto"
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case dynamic, black, graphite, midnight, light, white
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dynamic: return "Pochette"
        case .black: return "Noir"
        case .graphite: return "Graphite"
        case .midnight: return "Minuit"
        case .light: return "Clair"
        case .white: return "Blanc"
        }
    }
    var detail: String {
        switch self {
        case .dynamic: return "Le fond prend les couleurs de la pochette"
        case .black: return "Noir pur, idéal pour l’écran OLED"
        case .graphite: return "Gris sombre et neutre"
        case .midnight: return "Bleu nuit"
        case .light: return "Clair, teinté par la pochette"
        case .white: return "Blanc pur"
        }
    }
    var isLight: Bool { self == .light || self == .white }
    /// Aperçu pour le sélecteur.
    var swatch: [Color] {
        switch self {
        case .dynamic: return [Color(red: 0.55, green: 0.2, blue: 0.35), Color(red: 0.2, green: 0.25, blue: 0.5)]
        case .black: return [.black, .black]
        case .graphite: return [Color(white: 0.16), Color(white: 0.08)]
        case .midnight: return [Color(red: 0.07, green: 0.1, blue: 0.24), Color(red: 0.02, green: 0.03, blue: 0.09)]
        case .light: return [Color(red: 0.98, green: 0.92, blue: 0.94), Color(red: 0.9, green: 0.93, blue: 0.99)]
        case .white: return [.white, .white]
        }
    }
}

enum LyricsSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var label: String { self == .small ? "Petite" : (self == .medium ? "Moyenne" : "Grande") }
    var points: CGFloat { self == .small ? 25 : (self == .medium ? 31 : 37) }
}

enum ArtworkStyle: String, CaseIterable, Identifiable {
    case rounded, square
    var id: String { rawValue }
    var label: String { self == .rounded ? "Arrondies" : "Carrées" }
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
    var theme: AppTheme { didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") } }
    var appearance: AppearanceMode { didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") } }
    /// Réglage de l'iPhone (clair ou sombre), pour le mode Auto.
    var systemIsLight = false

    /// Le thème réellement affiché : celui choisi, éclairci ou assombri selon le mode.
    var activeTheme: AppTheme {
        let lightVersion: AppTheme = theme.isLight ? theme : .light
        let darkVersion: AppTheme = theme.isLight ? .dynamic : theme
        switch appearance {
        case .theme: return theme
        case .light: return lightVersion
        case .dark: return darkVersion
        case .auto: return systemIsLight ? lightVersion : darkVersion
        }
    }
    var lyricsSize: LyricsSize { didSet { UserDefaults.standard.set(lyricsSize.rawValue, forKey: "lyricsSize") } }
    var artworkStyle: ArtworkStyle { didSet { UserDefaults.standard.set(artworkStyle.rawValue, forKey: "artworkStyle") } }
    var backgroundMotion: Bool { didSet { UserDefaults.standard.set(backgroundMotion, forKey: "backgroundMotion") } }
    var showRecent: Bool { didSet { UserDefaults.standard.set(showRecent, forKey: "showRecent") } }
    var lockScreenAnimation: Bool { didSet { UserDefaults.standard.set(lockScreenAnimation, forKey: "lockScreenAnimation") } }
    /// Page d'un album : la pochette (animée) prend toute la largeur en haut et se fond dans le fond.
    var extendedAlbumArtwork: Bool { didSet { UserDefaults.standard.set(extendedAlbumArtwork, forKey: "extendedAlbumArtwork") } }
    /// Liquid Glass activé (sinon surfaces pleines) et sa transparence (0 = sombre, 1 = très transparent).
    /// Afficher le lecteur de Platine sur l'écran verrouillé et dans le Centre de contrôle.
    var lockScreenPlayer: Bool { didSet { UserDefaults.standard.set(lockScreenPlayer, forKey: "lockScreenPlayer") } }
    var liquidGlass: Bool { didSet { UserDefaults.standard.set(liquidGlass, forKey: "liquidGlass") } }
    var glassIntensity: Double { didSet { UserDefaults.standard.set(glassIntensity, forKey: "glassIntensity") } }

    /// Couleur d'accent lisible sur le thème choisi (le blanc devient noir sur un thème clair).
    var tint: Color { activeTheme.isLight && accent == .white ? .black : accent.color }

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
        theme = AppTheme(rawValue: d.string(forKey: "theme") ?? "") ?? .dynamic
        appearance = AppearanceMode(rawValue: d.string(forKey: "appearance") ?? "") ?? .theme
        lyricsSize = LyricsSize(rawValue: d.string(forKey: "lyricsSize") ?? "") ?? .medium
        artworkStyle = ArtworkStyle(rawValue: d.string(forKey: "artworkStyle") ?? "") ?? .rounded
        backgroundMotion = d.object(forKey: "backgroundMotion") as? Bool ?? true
        showRecent = d.object(forKey: "showRecent") as? Bool ?? true
        lockScreenAnimation = d.object(forKey: "lockScreenAnimation") as? Bool ?? true
        extendedAlbumArtwork = d.object(forKey: "extendedAlbumArtwork") as? Bool ?? true
        lockScreenPlayer = d.object(forKey: "lockScreenPlayer") as? Bool ?? true
        liquidGlass = d.object(forKey: "liquidGlass") as? Bool ?? true
        glassIntensity = d.object(forKey: "glassIntensity") as? Double ?? 0.6
    }
}

/// État de l'interface partagé entre les écrans.
@MainActor
@Observable
final class UIState {
    var showPlayer = false
    var editing: EditTarget?
    var editingInfo: EditTarget?
    /// Morceau ouvert dans le Studio remix.
    var remixing: EditTarget?
    var addToPlaylist: AddToPlaylistTarget?
    var importing = false
    var showShelf = false
    var selectedTab = 0
}

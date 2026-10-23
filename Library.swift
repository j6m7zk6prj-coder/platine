import Foundation
import AVFoundation
import ImageIO
import UIKit
import SwiftUI
import Observation

/// Bibliothèque musicale : fichiers copiés dans l'app, métadonnées, pochettes, playlists.
@MainActor
@Observable
final class Library {
    private(set) var tracks: [Track] = []
    private(set) var playlists: [Playlist] = []
    /// Photo choisie pour un artiste : identifiant de l'artiste → nom du fichier image.
    private(set) var artistImages: [String: String] = [:]
    /// Format choisi pour chaque album dans la Collection : identifiant de l'album → « cd » ou « cassette ».
    private(set) var albumFormats: [String: String] = [:]
    /// Stickers holographiques posés sur chaque album : identifiant de l'album → stickers.
    private(set) var albumStickers: [String: [String]] = [:]
    /// Jaquette choisie pour chaque jeu : nom du jeu → fichier image.
    private(set) var gameCovers: [String: String] = [:]
    /// Stickers faits à partir de tes images.
    private(set) var customStickers: [CustomSticker] = []
    /// Où chaque sticker est collé : album → sticker → position.
    private(set) var stickerPlacements: [String: [String: StickerPlacement]] = [:]
    /// Console choisie pour chaque jeu (PS3, PS4 ou PS5).
    private(set) var gamePlatforms: [String: String] = [:]
    /// Ajoute aussi les stickers gagnés automatiquement (or, platine, favori, nouveau).
    var autoStickers: Bool = UserDefaults.standard.bool(forKey: "autoStickers") {
        didSet { UserDefaults.standard.set(autoStickers, forKey: "autoStickers") }
    }
    var isImporting = false
    var message: String?
    /// Change à chaque modification de pochette (sert à rafraîchir l'écran verrouillé).
    private(set) var artworkRevision = 0

    @ObservationIgnored private var positions: [UUID: Int] = [:]
    @ObservationIgnored private let images = NSCache<NSString, UIImage>()
    @ObservationIgnored private var palettes: [String: [Color]] = [:]

    // Stockage interne, invisible dans l'app Fichiers.
    static let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Platine", isDirectory: true)
    static let musicDir = base.appendingPathComponent("Music", isDirectory: true)
    static let artDir = base.appendingPathComponent("Artwork", isDirectory: true)
    static let indexURL = base.appendingPathComponent("library.json")
    static let playlistsURL = base.appendingPathComponent("playlists.json")
    static let artistsURL = base.appendingPathComponent("artists.json")
    static let formatsURL = base.appendingPathComponent("formats.json")
    static let stickersURL = base.appendingPathComponent("stickers.json")
    static let gamesURL = base.appendingPathComponent("games.json")
    static let customStickersURL = base.appendingPathComponent("customstickers.json")
    static let placementsURL = base.appendingPathComponent("placements.json")
    static let platformsURL = base.appendingPathComponent("platforms.json")
    /// Dossier visible dans Fichiers et dans iTunes sur PC : tout ce qu'on y dépose est importé.
    static let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "alac", "m4b"]

    init() {
        for dir in [Self.musicDir, Self.artDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        load()
    }

    // MARK: Accès

    func track(_ id: UUID) -> Track? {
        guard let i = positions[id], i < tracks.count, tracks[i].id == id else {
            return tracks.first { $0.id == id }
        }
        return tracks[i]
    }

    func tracks(_ ids: [UUID]) -> [Track] { ids.compactMap { track($0) } }

    func playlist(_ id: UUID) -> Playlist? { playlists.first { $0.id == id } }

    func audioURL(_ t: Track) -> URL { Self.musicDir.appendingPathComponent(t.audioFile) }

    func artworkURL(_ t: Track) -> URL? {
        if let c = t.customArtwork { return Self.artDir.appendingPathComponent(c) }
        if let e = t.embeddedArtwork { return Self.artDir.appendingPathComponent(e) }
        return nil
    }

    func artworkKind(_ t: Track) -> ArtworkKind {
        t.customArtwork != nil ? (t.customKind ?? .image) : .image
    }

    var totalDuration: Double { tracks.reduce(0) { $0 + $1.duration } }

    var albums: [AlbumInfo] {
        Dictionary(grouping: tracks, by: \.albumKey).map { key, list in
            let sorted = list.sorted {
                if $0.trackNumber != $1.trackNumber { return ($0.trackNumber == 0 ? Int.max : $0.trackNumber) < ($1.trackNumber == 0 ? Int.max : $1.trackNumber) }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return AlbumInfo(id: key, title: sorted[0].displayAlbum, artist: sorted[0].displayArtist,
                             year: sorted.map(\.year).max() ?? 0, tracks: sorted)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func album(_ id: String) -> AlbumInfo? { albums.first { $0.id == id } }

    // MARK: Bandes-son de jeux

    /// Une « bande-son » par jeu tagué, présentée comme un album dans la Collection.
    var gameAlbums: [AlbumInfo] {
        var byGame: [String: [Track]] = [:]
        for t in tracks {
            for g in t.games { byGame[g, default: []].append(t) }
        }
        return byGame.map { game, list in
            AlbumInfo(id: GameCatalog.prefix + game, title: game, artist: "Bande-son",
                      year: GameCatalog.releaseYear(game),
                      tracks: list.sorted { $0.addedAt < $1.addedAt })
        }
        .sorted { $0.year != $1.year ? $0.year > $1.year : $0.title > $1.title }
    }

    /// Tous les jeux déjà utilisés (y compris ceux tapés à la main).
    var usedGames: [String] {
        Array(Set(tracks.flatMap(\.games))).sorted()
    }

    func setGames(_ id: UUID, _ games: [String]) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        var seen = Set<String>()
        tracks[i].games = games.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        save()
    }

    func gameName(_ albumID: String) -> String? {
        albumID.hasPrefix(GameCatalog.prefix) ? String(albumID.dropFirst(GameCatalog.prefix.count)) : nil
    }

    func gameCoverImage(_ game: String) -> UIImage? {
        guard let name = gameCovers[game] else { return nil }
        let key = name as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let img = UIImage(contentsOfFile: Self.artDir.appendingPathComponent(name).path) else { return nil }
        images.setObject(img, forKey: key)
        return img
    }

    func gameCoverName(_ game: String) -> String? { gameCovers[game] }

    /// Ta photo de la jaquette du jeu.
    func setGameCover(_ image: UIImage, for game: String) {
        // Taille raisonnable pour la 3D (une photo de 12 Mpx serait inutilement lourde).
        let maxSide: CGFloat = 1600
        let scale = min(1, maxSide / max(image.size.width, image.size.height, 1))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: target).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        guard let data = resized.jpegData(compressionQuality: 0.9) else { return }
        let name = "game-" + UUID().uuidString + ".jpg"
        do {
            try data.write(to: Self.artDir.appendingPathComponent(name), options: .atomic)
        } catch { return }
        if let old = gameCovers[game] { try? FileManager.default.removeItem(at: Self.artDir.appendingPathComponent(old)) }
        gameCovers[game] = name
        saveGames()
        artworkRevision += 1
        message = "Jaquette enregistrée"
    }

    func resetGameCover(_ game: String) {
        guard let old = gameCovers.removeValue(forKey: game) else { return }
        try? FileManager.default.removeItem(at: Self.artDir.appendingPathComponent(old))
        saveGames()
        artworkRevision += 1
    }

    private func saveGames() {
        guard let data = try? JSONEncoder().encode(gameCovers) else { return }
        try? data.write(to: Self.gamesURL, options: .atomic)
    }

    var artists: [ArtistInfo] {
        let allAlbums = albums
        return Dictionary(grouping: tracks, by: { $0.displayArtist.lowercased() }).map { key, list in
            ArtistInfo(id: key, name: list[0].displayArtist,
                       tracks: list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
                       albums: allAlbums.filter { $0.artist.lowercased() == key })
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func artist(_ id: String) -> ArtistInfo? { artists.first { $0.id == id } }

    var recentlyAdded: [AlbumInfo] {
        Array(albums.sorted { $0.latestAdd > $1.latestAdd }.prefix(12))
    }

    var recentlyPlayed: [Track] {
        Array(tracks.filter { $0.lastPlayed != nil }.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }.prefix(25))
    }

    var favorites: [Track] { tracks.filter(\.isFavorite) }

    var sortedPlaylists: [Playlist] {
        playlists.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func sorted(_ list: [Track], by sort: SongSort) -> [Track] {
        switch sort {
        case .title:
            return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            return list.sorted {
                let c = $0.displayArtist.localizedStandardCompare($1.displayArtist)
                return c == .orderedSame ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : c == .orderedAscending
            }
        case .album:
            return list.sorted {
                let c = $0.displayAlbum.localizedStandardCompare($1.displayAlbum)
                return c == .orderedSame ? $0.trackNumber < $1.trackNumber : c == .orderedAscending
            }
        case .recent:
            return list.sorted { $0.addedAt > $1.addedAt }
        case .mostPlayed:
            return list.sorted { $0.playCount > $1.playCount }
        }
    }

    func albumTrackIDs(of t: Track) -> Set<UUID> {
        guard !t.album.isEmpty else { return [t.id] }
        return Set(tracks.filter { $0.albumKey == t.albumKey }.map(\.id))
    }

    // MARK: Images

    /// Image fixe de la pochette. Pour une pochette animée (vidéo ou GIF), c'est la pochette
    /// d'origine du morceau ; s'il n'y en a pas, l'image la plus lumineuse de l'animation
    /// (jamais une image noire de début de vidéo).
    func image(for t: Track) -> UIImage? {
        guard let url = artworkURL(t) else { return nil }
        let key = url.lastPathComponent as NSString
        if let cached = images.object(forKey: key) { return cached }
        var img: UIImage?
        let kind = artworkKind(t)
        if kind == .video || kind == .gif {
            if let e = t.embeddedArtwork {
                img = UIImage(contentsOfFile: Self.artDir.appendingPathComponent(e).path)
            }
            if img == nil {
                img = kind == .video ? Self.bestVideoFrame(url) : Self.bestGIFFrame(url)
            }
        } else {
            img = UIImage(contentsOfFile: url.path)
        }
        if let img { images.setObject(img, forKey: key) }
        return img
    }

    /// Plusieurs images de la vidéo sont comparées : on garde la plus lumineuse et colorée.
    private static func bestVideoFrame(_ url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1000, height: 1000)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let total = max(0.2, asset.duration.seconds.isFinite ? asset.duration.seconds : 1)
        var best: (UIImage, CGFloat)?
        for f in [0.12, 0.3, 0.5, 0.7, 0.88] {
            guard let cg = try? gen.copyCGImage(at: CMTime(seconds: total * f, preferredTimescale: 600), actualTime: nil) else { continue }
            let img = UIImage(cgImage: cg)
            let score = Palette.liveliness(of: img)
            if best == nil || score > best!.1 { best = (img, score) }
        }
        return best?.0
    }

    private static func bestGIFFrame(_ url: URL) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return UIImage(contentsOfFile: url.path) }
        let count = CGImageSourceGetCount(src)
        guard count > 1 else { return UIImage(contentsOfFile: url.path) }
        var best: (UIImage, CGFloat)?
        for f in [0.0, 0.25, 0.5, 0.75] {
            guard let cg = CGImageSourceCreateImageAtIndex(src, min(count - 1, Int(Double(count) * f)), nil) else { continue }
            let img = UIImage(cgImage: cg)
            let score = Palette.liveliness(of: img)
            if best == nil || score > best!.1 { best = (img, score) }
        }
        return best?.0
    }

    func thumbnail(for t: Track) -> UIImage? {
        guard let url = artworkURL(t) else { return nil }
        let key = ("thumb-" + url.lastPathComponent) as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let full = image(for: t) else { return nil }
        let scale = 180 / max(full.size.width, full.size.height, 1)
        let size = CGSize(width: full.size.width * min(scale, 1), height: full.size.height * min(scale, 1))
        let thumb = full.preparingThumbnail(of: size) ?? full
        images.setObject(thumb, forKey: key)
        return thumb
    }

    func palette(for t: Track) -> [Color] {
        guard let url = artworkURL(t) else { return Palette.defaults }
        let key = url.lastPathComponent
        if let p = palettes[key] { return p }
        guard let img = thumbnail(for: t) else { return Palette.defaults }
        let p = Palette.colors(from: img)
        palettes[key] = p
        return p
    }

    // MARK: Import

    func importFiles(_ urls: [URL]) async {
        isImporting = true
        defer { isImporting = false }
        let lyricFiles = urls.filter { $0.pathExtension.lowercased() == "lrc" }
        let audioFiles = urls.filter { $0.pathExtension.lowercased() != "lrc" }
        var added = 0
        for url in audioFiles {
            let scoped = url.startAccessingSecurityScopedResource()
            let t = await importOne(url, move: false)
            if scoped { url.stopAccessingSecurityScopedResource() }
            if let t { tracks.append(t); added += 1 }
        }
        var lyricsAdded = 0
        for url in lyricFiles {
            let scoped = url.startAccessingSecurityScopedResource()
            if attachLyricsFile(url) { lyricsAdded += 1 }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        finishImport(added, total: audioFiles.count)
        if lyricsAdded > 0 && added == 0 {
            message = lyricsAdded == 1 ? "Paroles ajoutées" : "Paroles ajoutées à \(lyricsAdded) morceaux"
        } else if !lyricFiles.isEmpty && lyricsAdded == 0 && audioFiles.isEmpty {
            message = "Aucun morceau ne correspond à ces paroles"
        }
    }

    /// Ajoute les paroles d'un fichier .lrc au morceau qui porte le même nom.
    @discardableResult
    private func attachLyricsFile(_ url: URL) -> Bool {
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)),
              !text.isEmpty else { return false }
        let fromName = Self.parseFileName(url.deletingPathExtension().lastPathComponent)
        let fromTags = LyricsParser.tags(text)
        let candidates: [(title: String, artist: String)] = [
            (fromName.title, fromName.artist),
            (fromTags.title ?? "", fromTags.artist ?? "")
        ]
        for c in candidates where !c.title.isEmpty {
            let sameTitle = tracks.indices.filter {
                tracks[$0].title.compare(c.title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            let match = sameTitle.first { c.artist.isEmpty || tracks[$0].artist.localizedCaseInsensitiveContains(c.artist) } ?? sameTitle.first
            if let i = match {
                tracks[i].lyrics = text
                save()
                return true
            }
        }
        return false
    }

    func setLyrics(_ id: UUID, _ text: String?) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        let clean = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        tracks[i].lyrics = (clean?.isEmpty ?? true) ? nil : clean
        save()
    }

    /// « 01 - Artiste - Titre » → numéro, artiste, titre.
    static func parseFileName(_ name: String) -> (number: Int, artist: String, title: String) {
        var base = name
        var number = 0
        if let r = base.range(of: #"^\d{1,3}(?=[ ._-])"#, options: .regularExpression) {
            number = Int(base[r]) ?? 0
            base = String(base[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
        }
        let parts = base.components(separatedBy: " - ")
        if parts.count > 1 {
            return (number, parts[0].trimmingCharacters(in: .whitespaces),
                    parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces))
        }
        return (number, "", base)
    }

    /// Importe ce qui a été déposé dans le dossier « Platine » (Fichiers ou iTunes sur PC).
    func scanInbox() async {
        guard !isImporting else { return }
        let fm = FileManager.default
        var found: [URL] = []
        for dir in [Self.inbox, Self.inbox.appendingPathComponent("Inbox")] {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            found += items.filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
        }
        var lyricFiles: [URL] = []
        for dir in [Self.inbox, Self.inbox.appendingPathComponent("Inbox")] {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            lyricFiles += items.filter { $0.pathExtension.lowercased() == "lrc" }
        }
        guard !found.isEmpty || !lyricFiles.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }
        var added = 0
        for url in found {
            if let t = await importOne(url, move: true) { tracks.append(t); added += 1 }
        }
        for url in lyricFiles where attachLyricsFile(url) {
            try? fm.removeItem(at: url)
        }
        finishImport(added, total: found.count)
    }

    private func finishImport(_ added: Int, total: Int) {
        sortTracks()
        save()
        if added == 0 && total > 0 {
            message = "Ces fichiers ne sont pas lisibles"
        } else if added > 0 {
            message = added == 1 ? "1 morceau ajouté" : "\(added) morceaux ajoutés"
        }
    }

    private func importOne(_ src: URL, move: Bool) async -> Track? {
        let fm = FileManager.default
        let ext = src.pathExtension.lowercased()
        let name = UUID().uuidString + "." + (ext.isEmpty ? "m4a" : ext)
        let dest = Self.musicDir.appendingPathComponent(name)
        do {
            if move { try fm.moveItem(at: src, to: dest) } else { try fm.copyItem(at: src, to: dest) }
        } catch {
            return nil
        }

        let asset = AVURLAsset(url: dest)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        guard playable else {
            try? fm.removeItem(at: dest)
            return nil
        }

        // Nom de fichier « 01 - Artiste - Titre » en secours.
        let fromName = Self.parseFileName(src.deletingPathExtension().lastPathComponent)
        let trackNumber = fromName.number
        var title = fromName.title
        var artist = fromName.artist
        var album = ""
        var year = 0

        var artName: String?
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    if let v = try? await item.load(.stringValue), !v.isEmpty { title = v }
                case .commonKeyArtist:
                    if let v = try? await item.load(.stringValue), !v.isEmpty { artist = v }
                case .commonKeyAlbumName:
                    if let v = try? await item.load(.stringValue), !v.isEmpty { album = v }
                case .commonKeyCreationDate:
                    if let v = try? await item.load(.stringValue), let y = Int(v.prefix(4)) { year = y }
                case .commonKeyArtwork:
                    if artName == nil, let data = try? await item.load(.dataValue), let img = UIImage(data: data) {
                        artName = saveImage(img)
                    }
                default:
                    break
                }
            }
        }

        let lyricsValue: String? = (try? await asset.load(.lyrics)) ?? nil
        var duration = 0.0
        if let d = try? await asset.load(.duration), d.seconds.isFinite { duration = d.seconds }

        // Reprend la pochette d'un morceau du même album si celui-ci n'en a pas.
        if artName == nil, !album.isEmpty,
           let sibling = tracks.first(where: { $0.album == album && $0.artist == artist && $0.embeddedArtwork != nil }) {
            artName = sibling.embeddedArtwork
        }

        return Track(title: title, artist: artist, album: album, trackNumber: trackNumber, year: year,
                     duration: duration, audioFile: name, embeddedArtwork: artName,
                     lyrics: (lyricsValue?.isEmpty ?? true) ? nil : lyricsValue)
    }

    // MARK: Modifier les infos

    func updateInfo(_ id: UUID, title: String, artist: String, album: String, trackNumber: Int, year: Int, lyrics: String) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        let oldArtistKey = tracks[i].displayArtist.lowercased()
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        tracks[i].title = cleanTitle.isEmpty ? tracks[i].title : cleanTitle
        tracks[i].artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        tracks[i].album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        tracks[i].trackNumber = max(0, trackNumber)
        tracks[i].year = max(0, year)
        let cleanLyrics = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        tracks[i].lyrics = cleanLyrics.isEmpty ? nil : cleanLyrics
        carryArtistImage(from: oldArtistKey, to: tracks[i].displayArtist.lowercased())
        sortTracks()
        save()
        message = "Infos enregistrées"
    }

    /// Renomme un artiste sur tous ses morceaux. Renvoie le nouvel identifiant de l'artiste.
    @discardableResult
    func renameArtist(_ artistID: String, to name: String) -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return artistID }
        for i in tracks.indices where tracks[i].displayArtist.lowercased() == artistID {
            tracks[i].artist = clean
        }
        let newID = clean.lowercased()
        carryArtistImage(from: artistID, to: newID)
        save()
        message = "Artiste renommé"
        return newID
    }

    /// Renomme un album (et son artiste) sur tous ses morceaux. Renvoie le nouvel identifiant de l'album.
    @discardableResult
    func renameAlbum(_ albumID: String, title: String, artist: String) -> String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        var newID = albumID
        for i in tracks.indices where tracks[i].albumKey == albumID {
            let oldArtistKey = tracks[i].displayArtist.lowercased()
            if !cleanTitle.isEmpty { tracks[i].album = cleanTitle }
            if !cleanArtist.isEmpty { tracks[i].artist = cleanArtist }
            carryArtistImage(from: oldArtistKey, to: tracks[i].displayArtist.lowercased())
            newID = tracks[i].albumKey
        }
        if newID != albumID, let f = albumFormats.removeValue(forKey: albumID) {
            albumFormats[newID] = f
            saveFormats()
        }
        if newID != albumID, let st = albumStickers.removeValue(forKey: albumID) {
            albumStickers[newID] = st
            saveStickers()
        }
        save()
        message = "Album modifié"
        return newID
    }

    // MARK: Collection

    func format(of albumID: String, default fallback: AlbumFormat) -> AlbumFormat {
        if albumID.hasPrefix(GameCatalog.prefix) { return .game }
        return AlbumFormat(rawValue: albumFormats[albumID] ?? "") ?? fallback
    }

    func setFormat(_ format: AlbumFormat, for albumID: String) {
        albumFormats[albumID] = format.rawValue
        saveFormats()
    }

    /// Stickers d'un album : ceux posés à la main, puis (si l'option est activée) ceux gagnés.
    func badges(for album: AlbumInfo) -> [AlbumBadge] {
        var result = stickers(for: album.id)
        guard autoStickers else { return result }
        for b in earnedBadges(for: album) where !result.contains(b) { result.append(b) }
        return Array(result.prefix(4))
    }

    func stickers(for albumID: String) -> [AlbumBadge] {
        (albumStickers[albumID] ?? []).compactMap(AlbumBadge.init(rawValue:))
    }

    /// Pose ou retire un sticker (3 au maximum par album).
    func toggleSticker(_ badge: AlbumBadge, for albumID: String) {
        var list = albumStickers[albumID] ?? []
        if let i = list.firstIndex(of: badge.rawValue) {
            list.remove(at: i)
        } else {
            if list.count >= 3 { list.removeFirst() }
            list.append(badge.rawValue)
        }
        albumStickers[albumID] = list.isEmpty ? nil : list
        saveStickers()
    }

    /// Tes stickers posés sur cet album.
    func customStickers(for albumID: String) -> [CustomSticker] {
        let keys = albumStickers[albumID] ?? []
        return keys.compactMap { key in customStickers.first { $0.key == key } }
    }

    /// Liste brute (sert à savoir quand reconstruire le modèle 3D).
    func stickerKeys(for albumID: String) -> [String] { albumStickers[albumID] ?? [] }

    func toggleCustomSticker(_ sticker: CustomSticker, for albumID: String) {
        var list = albumStickers[albumID] ?? []
        if let i = list.firstIndex(of: sticker.key) {
            list.remove(at: i)
        } else {
            if list.count >= 3 { list.removeFirst() }
            list.append(sticker.key)
        }
        albumStickers[albumID] = list.isEmpty ? nil : list
        saveStickers()
    }

    func customStickerImage(_ sticker: CustomSticker) -> UIImage? {
        let key = sticker.file as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let img = UIImage(contentsOfFile: Self.artDir.appendingPathComponent(sticker.file).path) else { return nil }
        images.setObject(img, forKey: key)
        return img
    }

    /// Crée un sticker à partir d'une image (déjà recadrée).
    @discardableResult
    func addCustomSticker(_ image: UIImage, finish: StickerFinish, round: Bool) -> CustomSticker? {
        let side: CGFloat = 600
        let resized = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        guard let data = resized.pngData() else { return nil }
        let name = "sticker-" + UUID().uuidString + ".png"
        do { try data.write(to: Self.artDir.appendingPathComponent(name), options: .atomic) } catch { return nil }
        let sticker = CustomSticker(file: name, finish: finish, round: round)
        customStickers.append(sticker)
        saveCustomStickers()
        return sticker
    }

    func deleteCustomSticker(_ sticker: CustomSticker) {
        customStickers.removeAll { $0.id == sticker.id }
        for (album, list) in albumStickers {
            let kept = list.filter { $0 != sticker.key }
            albumStickers[album] = kept.isEmpty ? nil : kept
        }
        try? FileManager.default.removeItem(at: Self.artDir.appendingPathComponent(sticker.file))
        saveCustomStickers()
        saveStickers()
    }

    // MARK: Position des stickers

    /// Clés des stickers affichés sur un album, dans l'ordre (gagnés/choisis puis les tiens).
    func stickerOrder(for album: AlbumInfo, badges: [AlbumBadge]) -> [String] {
        badges.map(\.rawValue) + customStickers(for: album.id).map(\.key)
    }

    func placement(_ key: String, index: Int, albumID: String) -> StickerPlacement {
        stickerPlacements[albumID]?[key] ?? .standard(index)
    }

    func setPlacements(_ map: [String: StickerPlacement], for albumID: String) {
        stickerPlacements[albumID] = map.isEmpty ? nil : map
        savePlacements()
        artworkRevision += 1
    }

    /// Résumé des positions (sert à savoir quand redessiner la jaquette en 3D).
    func placementSignature(_ albumID: String) -> String {
        guard let map = stickerPlacements[albumID] else { return "" }
        var parts: [String] = []
        for key in map.keys.sorted() {
            let value: String = map[key]?.signature ?? ""
            parts.append(key + "=" + value)
        }
        return parts.joined(separator: ";")
    }

    private func savePlacements() {
        guard let data = try? JSONEncoder().encode(stickerPlacements) else { return }
        try? data.write(to: Self.placementsURL, options: .atomic)
    }

    // MARK: Console du boîtier de jeu

    func platform(of game: String) -> GamePlatform {
        GamePlatform(rawValue: gamePlatforms[game] ?? "") ?? .ps5
    }

    func setPlatform(_ platform: GamePlatform, for game: String) {
        gamePlatforms[game] = platform.rawValue
        artworkRevision += 1
        guard let data = try? JSONEncoder().encode(gamePlatforms) else { return }
        try? data.write(to: Self.platformsURL, options: .atomic)
    }

    private func saveCustomStickers() {
        guard let data = try? JSONEncoder().encode(customStickers) else { return }
        try? data.write(to: Self.customStickersURL, options: .atomic)
    }

    func clearStickers(for albumID: String) {
        albumStickers[albumID] = nil
        saveStickers()
    }

    private func saveStickers() {
        guard let data = try? JSONEncoder().encode(albumStickers) else { return }
        try? data.write(to: Self.stickersURL, options: .atomic)
    }

    /// Badges gagnés : or et platine selon les écoutes de l'album, favori, nouveauté.
    func earnedBadges(for album: AlbumInfo) -> [AlbumBadge] {
        var result: [AlbumBadge] = []
        let plays = album.tracks.reduce(0) { $0 + $1.playCount }
        if plays >= 100 { result.append(.platinum) } else if plays >= 50 { result.append(.gold) }
        if album.tracks.contains(where: \.isFavorite) { result.append(.favorite) }
        if album.latestAdd > Date().addingTimeInterval(-14 * 24 * 3600) { result.append(.new) }
        return result
    }

    private func saveFormats() {
        guard let data = try? JSONEncoder().encode(albumFormats) else { return }
        try? data.write(to: Self.formatsURL, options: .atomic)
    }

    // MARK: Photos d'artiste

    func artistImage(_ artistID: String) -> UIImage? {
        guard let name = artistImages[artistID] else { return nil }
        let key = name as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let img = UIImage(contentsOfFile: Self.artDir.appendingPathComponent(name).path) else { return nil }
        images.setObject(img, forKey: key)
        return img
    }

    func setArtistImage(_ artistID: String, image: UIImage) {
        guard let name = saveImage(image, prefix: "artist-") else {
            message = "Impossible d’enregistrer cette photo"
            return
        }
        let old = artistImages[artistID]
        artistImages[artistID] = name
        if let old { removeArtistFile(old) }
        saveArtists()
        message = "Photo de l’artiste mise à jour"
    }

    func resetArtistImage(_ artistID: String) {
        guard let old = artistImages.removeValue(forKey: artistID) else { return }
        removeArtistFile(old)
        saveArtists()
        message = "Photo retirée"
    }

    /// Garde la photo d'un artiste quand son nom change.
    private func carryArtistImage(from oldID: String, to newID: String) {
        guard oldID != newID, let name = artistImages[oldID] else { return }
        // Si d'autres morceaux portent encore l'ancien nom, la photo reste aussi sur l'ancien artiste.
        let stillUsed = tracks.contains { $0.displayArtist.lowercased() == oldID }
        if artistImages[newID] == nil { artistImages[newID] = name }
        if !stillUsed { artistImages[oldID] = nil }
        saveArtists()
    }

    private func removeArtistFile(_ name: String) {
        // Ne supprime le fichier que si plus aucun artiste ne l'utilise.
        guard !artistImages.values.contains(name) else { return }
        try? FileManager.default.removeItem(at: Self.artDir.appendingPathComponent(name))
        images.removeObject(forKey: name as NSString)
    }

    // MARK: Favoris et écoutes

    func toggleFavorite(_ id: UUID) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].isFavorite.toggle()
        save()
        message = tracks[i].isFavorite ? "Ajouté aux favoris" : "Retiré des favoris"
    }

    func recordPlay(_ id: UUID) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].playCount += 1
        tracks[i].lastPlayed = Date()
        save()
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(name: String, trackIDs: [UUID] = []) -> Playlist {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = Playlist(name: clean.isEmpty ? "Nouvelle playlist" : clean, trackIDs: trackIDs)
        playlists.append(p)
        savePlaylists()
        message = trackIDs.isEmpty ? "Playlist créée" : "Ajouté à « \(p.name) »"
        return p
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = clean
        savePlaylists()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        savePlaylists()
        message = "Playlist supprimée"
    }

    func togglePin(_ id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].pinned.toggle()
        savePlaylists()
    }

    func add(_ ids: [UUID], toPlaylist id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].trackIDs.append(contentsOf: ids)
        savePlaylists()
        message = ids.count > 1 ? "\(ids.count) morceaux ajoutés à « \(playlists[i].name) »" : "Ajouté à « \(playlists[i].name) »"
    }

    func removeFromPlaylist(_ id: UUID, offsets: IndexSet) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].trackIDs.remove(atOffsets: offsets)
        savePlaylists()
    }

    func movePlaylistTracks(_ id: UUID, from: IndexSet, to: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].trackIDs.move(fromOffsets: from, toOffset: to)
        savePlaylists()
    }

    // MARK: Pochettes personnalisées

    func setCustomImage(_ ids: Set<UUID>, image: UIImage) {
        guard let name = saveImage(image, prefix: "custom-") else {
            message = "Impossible d’enregistrer cette image"
            return
        }
        assign(name, kind: .image, to: ids)
    }

    func setCustomArtwork(_ ids: Set<UUID>, file: URL, kind: ArtworkKind) {
        let ext = file.pathExtension.isEmpty ? (kind == .video ? "mov" : "gif") : file.pathExtension.lowercased()
        let name = "custom-" + UUID().uuidString + "." + ext
        do {
            try FileManager.default.copyItem(at: file, to: Self.artDir.appendingPathComponent(name))
        } catch {
            message = "Impossible d’importer ce fichier"
            return
        }
        assign(name, kind: kind, to: ids)
    }

    func setCustomArtwork(_ ids: Set<UUID>, data: Data, ext: String, kind: ArtworkKind) {
        let name = "custom-" + UUID().uuidString + "." + ext
        do {
            try data.write(to: Self.artDir.appendingPathComponent(name), options: .atomic)
        } catch {
            message = "Impossible d’enregistrer ce fichier"
            return
        }
        assign(name, kind: kind, to: ids)
    }

    func resetArtwork(_ ids: Set<UUID>) {
        for i in tracks.indices where ids.contains(tracks[i].id) {
            let previous = tracks[i].customArtwork
            tracks[i].customArtwork = nil
            tracks[i].customKind = nil
            if let previous { cleanupArtwork(previous) }
        }
        artworkRevision += 1
        save()
        message = "Pochette d’origine rétablie"
    }

    private func assign(_ name: String, kind: ArtworkKind, to ids: Set<UUID>) {
        for i in tracks.indices where ids.contains(tracks[i].id) {
            let previous = tracks[i].customArtwork
            tracks[i].customArtwork = name
            tracks[i].customKind = kind
            if let previous { cleanupArtwork(previous) }
        }
        artworkRevision += 1
        save()
        message = ids.count > 1 ? "Pochette appliquée à \(ids.count) morceaux" : "Pochette mise à jour"
    }

    // MARK: Suppression

    func remove(_ ids: Set<UUID>) {
        let gone = tracks.filter { ids.contains($0.id) }
        tracks.removeAll { ids.contains($0.id) }
        for t in gone {
            try? FileManager.default.removeItem(at: audioURL(t))
            for art in [t.customArtwork, t.embeddedArtwork].compactMap({ $0 }) { cleanupArtwork(art) }
        }
        for i in playlists.indices {
            playlists[i].trackIDs.removeAll { ids.contains($0) }
        }
        save()
        savePlaylists()
    }

    func removeAll() {
        let fm = FileManager.default
        try? fm.removeItem(at: Self.musicDir)
        try? fm.removeItem(at: Self.artDir)
        for dir in [Self.musicDir, Self.artDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        tracks = []
        playlists = []
        artistImages = [:]
        albumFormats = [:]
        saveFormats()
        albumStickers = [:]
        saveStickers()
        gameCovers = [:]
        saveGames()
        customStickers = []
        saveCustomStickers()
        images.removeAllObjects()
        palettes = [:]
        save()
        savePlaylists()
        saveArtists()
        message = "Bibliothèque vidée"
    }

    /// Espace occupé par la musique et les pochettes, en octets.
    func storageBytes() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for dir in [Self.musicDir, Self.artDir] {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for url in items {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    /// Supprime un fichier de pochette s'il n'est plus utilisé par aucun morceau.
    private func cleanupArtwork(_ name: String) {
        guard !tracks.contains(where: { $0.customArtwork == name || $0.embeddedArtwork == name }) else { return }
        try? FileManager.default.removeItem(at: Self.artDir.appendingPathComponent(name))
        images.removeObject(forKey: name as NSString)
        images.removeObject(forKey: ("thumb-" + name) as NSString)
        palettes[name] = nil
    }

    // MARK: Persistance

    private func saveImage(_ image: UIImage, prefix: String = "") -> String? {
        let maxSide: CGFloat = 1400
        let scale = min(1, maxSide / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = resized.jpegData(compressionQuality: 0.9) else { return nil }
        let name = prefix + UUID().uuidString + ".jpg"
        do {
            try data.write(to: Self.artDir.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    private func sortTracks() {
        tracks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func reindex() {
        var map: [UUID: Int] = [:]
        for (i, t) in tracks.enumerated() { map[t.id] = i }
        positions = map
    }

    private func load() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let list = try? JSONDecoder().decode([Track].self, from: data) {
            tracks = list.filter { FileManager.default.fileExists(atPath: Self.musicDir.appendingPathComponent($0.audioFile).path) }
            sortTracks()
        }
        if let data = try? Data(contentsOf: Self.playlistsURL),
           let list = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = list
        }
        if let data = try? Data(contentsOf: Self.formatsURL),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            albumFormats = map
        }
        if let data = try? Data(contentsOf: Self.placementsURL),
           let map = try? JSONDecoder().decode([String: [String: StickerPlacement]].self, from: data) {
            stickerPlacements = map
        }
        if let data = try? Data(contentsOf: Self.platformsURL),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            gamePlatforms = map
        }
        if let data = try? Data(contentsOf: Self.customStickersURL),
           let list = try? JSONDecoder().decode([CustomSticker].self, from: data) {
            customStickers = list
        }
        if let data = try? Data(contentsOf: Self.gamesURL),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            gameCovers = map
        }
        if let data = try? Data(contentsOf: Self.stickersURL),
           let map = try? JSONDecoder().decode([String: [String]].self, from: data) {
            albumStickers = map
        }
        if let data = try? Data(contentsOf: Self.artistsURL),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            artistImages = map
        }
        reindex()
    }

    private func saveArtists() {
        guard let data = try? JSONEncoder().encode(artistImages) else { return }
        try? data.write(to: Self.artistsURL, options: .atomic)
    }

    private func save() {
        reindex()
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        try? data.write(to: Self.indexURL, options: .atomic)
    }

    private func savePlaylists() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        try? data.write(to: Self.playlistsURL, options: .atomic)
    }
}

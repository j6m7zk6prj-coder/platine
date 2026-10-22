import Foundation
import AVFoundation
import UIKit
import SwiftUI
import Observation

/// Bibliothèque musicale : fichiers copiés dans l'app, métadonnées, pochettes.
@MainActor
@Observable
final class Library {
    private(set) var tracks: [Track] = []
    var isImporting = false
    var message: String?
    /// Change à chaque modification de pochette (sert à rafraîchir l'écran verrouillé).
    private(set) var artworkRevision = 0

    @ObservationIgnored private let images = NSCache<NSString, UIImage>()
    @ObservationIgnored private var palettes: [String: [Color]] = [:]

    // Stockage interne, invisible dans l'app Fichiers.
    static let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Platine", isDirectory: true)
    static let musicDir = base.appendingPathComponent("Music", isDirectory: true)
    static let artDir = base.appendingPathComponent("Artwork", isDirectory: true)
    static let indexURL = base.appendingPathComponent("library.json")
    /// Dossier visible dans Fichiers et dans l'app Appareils Apple sur PC : tout ce qu'on y dépose est importé.
    static let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "alac", "m4b"]

    init() {
        for dir in [Self.musicDir, Self.artDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        load()
    }

    // MARK: Accès

    func track(_ id: UUID) -> Track? { tracks.first { $0.id == id } }

    func audioURL(_ t: Track) -> URL { Self.musicDir.appendingPathComponent(t.audioFile) }

    func artworkURL(_ t: Track) -> URL? {
        if let c = t.customArtwork { return Self.artDir.appendingPathComponent(c) }
        if let e = t.embeddedArtwork { return Self.artDir.appendingPathComponent(e) }
        return nil
    }

    func artworkKind(_ t: Track) -> ArtworkKind {
        t.customArtwork != nil ? (t.customKind ?? .image) : .image
    }

    func albumTrackIDs(of t: Track) -> Set<UUID> {
        guard !t.album.isEmpty else { return [t.id] }
        return Set(tracks.filter { $0.album == t.album && $0.artist == t.artist }.map(\.id))
    }

    var totalDuration: Double { tracks.reduce(0) { $0 + $1.duration } }

    // MARK: Images

    /// Image fixe de la pochette (1re image d'un GIF, image extraite d'une vidéo).
    func image(for t: Track) -> UIImage? {
        guard let url = artworkURL(t) else { return nil }
        let key = url.lastPathComponent as NSString
        if let cached = images.object(forKey: key) { return cached }
        var img: UIImage?
        if artworkKind(t) == .video {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 1000, height: 1000)
            if let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil) {
                img = UIImage(cgImage: cg)
            }
        } else {
            img = UIImage(contentsOfFile: url.path)
        }
        if let img { images.setObject(img, forKey: key) }
        return img
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
        var added = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            let t = await importOne(url, move: false)
            if scoped { url.stopAccessingSecurityScopedResource() }
            if let t { tracks.append(t); added += 1 }
        }
        finishImport(added, total: urls.count)
    }

    /// Importe ce qui a été déposé dans le dossier « Platine » (Fichiers ou PC).
    func scanInbox() async {
        guard !isImporting else { return }
        let fm = FileManager.default
        var found: [URL] = []
        for dir in [Self.inbox, Self.inbox.appendingPathComponent("Inbox")] {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            found += items.filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
        }
        guard !found.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }
        var added = 0
        for url in found {
            if let t = await importOne(url, move: true) { tracks.append(t); added += 1 }
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

        // Nom de fichier « Artiste - Titre » en secours.
        var title = src.deletingPathExtension().lastPathComponent
        var artist = ""
        var album = ""
        let parts = title.components(separatedBy: " - ")
        if parts.count > 1 {
            artist = parts[0].trimmingCharacters(in: .whitespaces)
            title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        }

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
                case .commonKeyArtwork:
                    if artName == nil, let data = try? await item.load(.dataValue), let img = UIImage(data: data) {
                        artName = saveImage(img)
                    }
                default:
                    break
                }
            }
        }

        var duration = 0.0
        if let d = try? await asset.load(.duration), d.seconds.isFinite { duration = d.seconds }

        return Track(title: title, artist: artist, album: album, duration: duration,
                     audioFile: name, embeddedArtwork: artName)
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
        save()
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

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let list = try? JSONDecoder().decode([Track].self, from: data) else { return }
        tracks = list.filter { FileManager.default.fileExists(atPath: Self.musicDir.appendingPathComponent($0.audioFile).path) }
        sortTracks()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        try? data.write(to: Self.indexURL, options: .atomic)
    }
}

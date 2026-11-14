import Foundation

// MARK: - Infos automatiques : l'album (Apple Music) et les paroles synchronisées (LRCLIB)

/// Après un envoi depuis le PC, chaque morceau est complété tout seul :
/// l'album, l'année et le numéro de piste, puis les paroles synchronisées.
/// Il ne reste qu'à ajouter la pochette.
@MainActor
enum TrackEnricher {
    struct Result: Encodable {
        var id: String?
        var title: String?
        var artist: String?
        var album: String?
        /// Vrai si la pochette a été trouvée et posée automatiquement.
        var cover = false
        /// « synchro », « texte » ou « aucune ».
        var lyrics: String
    }

    static func enrich(_ id: UUID, library: Library) async -> Result {
        guard let t = library.track(id) else { return Result(album: nil, lyrics: "aucune") }
        var coverSet = false

        // 1. L'album (si le fichier ne le dit pas) et la pochette (si le fichier n'en a pas), comme Musique sur PC.
        let noArtwork = library.artworkURL(t) == nil
        if t.album.isEmpty || noArtwork, let found = await findAlbum(title: t.title, artist: t.artist, duration: t.duration) {
            library.fillInfo(id, album: found.album, year: found.year, trackNumber: found.number)
            if noArtwork, let url = found.cover, let data = await download(url), let now = library.track(id) {
                if now.album.isEmpty {
                    library.setCustomArtwork([id], data: data, ext: "jpg", kind: .image)
                } else {
                    library.setAlbumCover(now.albumKey, data: data, ext: "jpg", kind: .image)
                }
                coverSet = true
            }
        }

        // 2. Les paroles synchronisées, si le fichier n'en a pas.
        let current = library.track(id)
        var lyrics = "aucune"
        if let l = current?.lyrics, !l.isEmpty { lyrics = LyricsParser.isSynced(l) ? "synchro" : "texte" }
        if lyrics != "synchro", let c = current,
           let found = await LyricsService.search(title: c.title, artist: c.artist, duration: c.duration) {
            if LyricsParser.isSynced(found) {
                library.setLyrics(id, found)
                lyrics = "synchro"
            } else if lyrics == "aucune" {
                library.setLyrics(id, found)
                lyrics = "texte"
            }
        }
        let final = library.track(id)
        let album = final?.album
        return Result(id: id.uuidString, title: final?.title, artist: final?.displayArtist,
                      album: (album?.isEmpty ?? true) ? nil : album, cover: coverSet, lyrics: lyrics)
    }

    /// Toute la bibliothèque, en douceur et une seule fois par morceau : paroles synchronisées,
    /// album et pochette qui manquent encore (y compris pour les sons importés avant).
    static func fillLibrary(_ library: Library) async {
        let key = "enrichedV3"
        var done = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        var improved = 0
        for t in library.tracks where !done.contains(t.id.uuidString) {
            if Task.isCancelled { return }
            let needs = !LyricsParser.isSynced(t.lyrics ?? "") || t.album.isEmpty || library.artworkURL(t) == nil
            if needs {
                let before = library.track(t.id)
                let r = await enrich(t.id, library: library)
                // Pas de bandeau à chaque morceau.
                library.message = nil
                if r.cover || (r.lyrics == "synchro" && !LyricsParser.isSynced(before?.lyrics ?? ""))
                    || (before?.album.isEmpty == true && r.album != nil) { improved += 1 }
                try? await Task.sleep(for: .milliseconds(250))
            }
            done.insert(t.id.uuidString)
            UserDefaults.standard.set(Array(done), forKey: key)
        }
        if improved > 0 {
            library.message = improved > 1 ? "Paroles et pochettes complétées pour \(improved) morceaux" : "Paroles et pochette complétées"
        }
    }

    private static func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 1000 else { return nil }
        return data
    }

    // MARK: Recherche de l'album (catalogue Apple, sans compte)

    private struct Search: Decodable { let results: [Song] }
    private struct Song: Decodable {
        let trackName: String?
        let artistName: String?
        let collectionName: String?
        let trackNumber: Int?
        let releaseDate: String?
        let trackTimeMillis: Int?
        let collectionType: String?
        let trackCount: Int?
        let artworkUrl100: String?
    }

    struct Found {
        let album: String
        let year: Int
        let number: Int
        var cover: URL?
    }

    static func findAlbum(title: String, artist: String, duration: Double) async -> Found? {
        // Le catalogue officiel d'Apple Music d'abord ; Deezer si Apple ne trouve pas le morceau.
        if let a = await itunes(title: title, artist: artist, duration: duration) { return a }
        return await deezer(title: title, artist: artist, duration: duration)
    }

    // MARK: Deezer (sans compte)

    private struct DZSearch: Decodable { let data: [DZTrack]? }
    private struct DZTrack: Decodable {
        let id: Int
        let title: String?
        let duration: Int?
        let artist: DZName?
        let album: DZAlbumRef?
    }
    private struct DZName: Decodable { let name: String? }
    private struct DZAlbumRef: Decodable { let id: Int; let title: String? }
    private struct DZAlbum: Decodable { let record_type: String?; let release_date: String?; let title: String?; let cover_xl: String? }
    private struct DZTrackFull: Decodable { let track_position: Int?; let release_date: String? }

    private static func get<T: Decodable>(_ url: URL, as: T.Type) async -> T? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func deezer(title: String, artist: String, duration: Double) async -> Found? {
        let q = artist.isEmpty ? "track:\"\(title)\"" : "artist:\"\(artist)\" track:\"\(title)\""
        var tracks: [DZTrack] = []
        for query in [q, "\(artist) \(title)"] {
            guard var c = URLComponents(string: "https://api.deezer.com/search") else { return nil }
            c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "25")]
            guard let url = c.url, let r = await get(url, as: DZSearch.self) else { continue }
            tracks = r.data ?? []
            if !tracks.isEmpty { break }
        }
        let t = LyricsService.norm(title), a = LyricsService.norm(artist)
        func gap(_ x: DZTrack) -> Double { duration > 0 ? abs(Double(x.duration ?? 0) - duration) : 0 }
        let same = tracks.filter { x in
            LyricsService.matches(LyricsService.norm(x.title ?? ""), t)
                && (a.isEmpty || LyricsService.matches(LyricsService.norm(x.artist?.name ?? ""), a))
                && x.album != nil
        }
        let close = same.filter { gap($0) <= 6 }
        let candidates = Array((close.isEmpty ? same : close).sorted { gap($0) < gap($1) }.prefix(4))
        guard !candidates.isEmpty else { return nil }
        // On préfère l'album au single : on regarde le type de chaque sortie.
        var best: (DZTrack, DZAlbum)?
        for x in candidates {
            guard let ref = x.album, let url = URL(string: "https://api.deezer.com/album/\(ref.id)"),
                  let alb = await get(url, as: DZAlbum.self) else { continue }
            if best == nil { best = (x, alb) }
            if alb.record_type == "album" { best = (x, alb); break }
        }
        guard let (x, alb) = best, let name = alb.title ?? x.album?.title else { return nil }
        let single = alb.record_type == "single"
        var number = 0
        if !single, let url = URL(string: "https://api.deezer.com/track/\(x.id)"),
           let full = await get(url, as: DZTrackFull.self) {
            number = full.track_position ?? 0
        }
        let year = Int((alb.release_date ?? "").prefix(4)) ?? 0
        return Found(album: name, year: year, number: number, cover: alb.cover_xl.flatMap(URL.init(string:)))
    }

    // MARK: Catalogue Apple (sans compte)

    private static func itunes(title: String, artist: String, duration: Double) async -> Found? {
        let term = [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
        guard !term.isEmpty else { return nil }
        for country in ["FR", "US"] {
            guard var c = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
            c.queryItems = [URLQueryItem(name: "term", value: term),
                            URLQueryItem(name: "media", value: "music"),
                            URLQueryItem(name: "entity", value: "song"),
                            URLQueryItem(name: "limit", value: "25"),
                            URLQueryItem(name: "country", value: country)]
            guard let url = c.url else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            guard let (data, resp) = try? await URLSession.shared.data(for: request),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let search = try? JSONDecoder().decode(Search.self, from: data) else { continue }
            if let best = pick(search.results, title: title, artist: artist, duration: duration) { return best }
        }
        return nil
    }

    /// Le bon morceau : même titre, même artiste ; on préfère le vrai album au single, et la durée la plus proche.
    private static func pick(_ songs: [Song], title: String, artist: String, duration: Double) -> Found? {
        let t = LyricsService.norm(title), a = LyricsService.norm(artist)
        let same = songs.filter { s in
            LyricsService.matches(LyricsService.norm(s.trackName ?? ""), t)
                && (a.isEmpty || LyricsService.matches(LyricsService.norm(s.artistName ?? ""), a))
                && !(s.collectionName ?? "").isEmpty
        }
        func gap(_ s: Song) -> Double {
            guard duration > 0, let ms = s.trackTimeMillis else { return 0 }
            return abs(Double(ms) / 1000 - duration)
        }
        func isSingle(_ s: Song) -> Bool {
            let name = (s.collectionName ?? "").lowercased()
            return name.hasSuffix(" - single") || name.hasSuffix(" - ep") || (s.trackCount ?? 2) <= 1
        }
        let close = same.filter { gap($0) <= 6 }
        let pool = close.isEmpty ? same : close
        guard let best = pool.min(by: { l, r in
            if isSingle(l) != isSingle(r) { return !isSingle(l) }
            return gap(l) < gap(r)
        }) else { return nil }
        var name = best.collectionName ?? ""
        for suffix in [" - Single", " - EP"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        let year = Int((best.releaseDate ?? "").prefix(4)) ?? 0
        let art = best.artworkUrl100.map { $0.replacingOccurrences(of: "100x100bb", with: "3000x3000bb") }
        return Found(album: name, year: year, number: isSingle(best) ? 0 : (best.trackNumber ?? 0),
                     cover: art.flatMap(URL.init(string:)))
    }
}

import Foundation

// MARK: - Infos automatiques : l'album (Apple Music) et les paroles synchronisées (LRCLIB)

/// Après un envoi depuis le PC, chaque morceau est complété tout seul :
/// l'album, l'année et le numéro de piste, puis les paroles synchronisées.
/// Il ne reste qu'à ajouter la pochette.
@MainActor
enum TrackEnricher {
    struct Result: Encodable {
        var album: String?
        /// « synchro », « texte » ou « aucune ».
        var lyrics: String
    }

    static func enrich(_ id: UUID, library: Library) async -> Result {
        guard let t = library.track(id) else { return Result(album: nil, lyrics: "aucune") }

        // 1. L'album, si le fichier ne le dit pas.
        if t.album.isEmpty, let found = await findAlbum(title: t.title, artist: t.artist, duration: t.duration) {
            library.fillInfo(id, album: found.album, year: found.year, trackNumber: found.number)
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
        let album = library.track(id)?.album
        return Result(album: (album?.isEmpty ?? true) ? nil : album, lyrics: lyrics)
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
    }

    struct Found {
        let album: String
        let year: Int
        let number: Int
    }

    static func findAlbum(title: String, artist: String, duration: Double) async -> Found? {
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
        return Found(album: name, year: year, number: isSingle(best) ? 0 : (best.trackNumber ?? 0))
    }
}

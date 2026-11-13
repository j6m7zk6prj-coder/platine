import Foundation
import UniformTypeIdentifiers

/// Une ligne de paroles synchronisées.
struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
    var isInterlude: Bool { text.isEmpty }
}

extension UTType {
    /// Fichier de paroles synchronisées (.lrc).
    static let lrc = UTType(filenameExtension: "lrc") ?? .plainText
}

/// Lit le format LRC : « [01:23.45]Texte de la ligne ».
enum LyricsParser {
    private static let timeTag = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    private static let offsetTag = try! NSRegularExpression(pattern: #"\[offset:\s*([+-]?\d+)\]"#, options: .caseInsensitive)

    /// Vrai si le texte contient des repères de temps.
    static func isSynced(_ raw: String) -> Bool {
        let ns = raw as NSString
        return timeTag.numberOfMatches(in: raw, range: NSRange(location: 0, length: min(ns.length, 4000))) >= 2
    }

    /// Renvoie les lignes triées par temps, ou nil si ce ne sont pas des paroles synchronisées.
    static func parse(_ raw: String) -> [LyricLine]? {
        var offset = 0.0
        var entries: [(Double, String)] = []

        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)

            if let m = offsetTag.firstMatch(in: line, range: range), let ms = Double(ns.substring(with: m.range(at: 1))) {
                offset = ms / 1000
                continue
            }

            let matches = timeTag.matches(in: line, range: range)
            guard let last = matches.last else { continue }
            var text = ns.substring(from: last.range.location + last.range.length)
            // Repères par mot (LRC enrichi) : on les retire.
            text = text.replacingOccurrences(of: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#, with: "", options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespaces)

            for m in matches {
                guard let minutes = Double(ns.substring(with: m.range(at: 1))),
                      let seconds = Double(ns.substring(with: m.range(at: 2))) else { continue }
                var fraction = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let digits = ns.substring(with: m.range(at: 3))
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                entries.append((minutes * 60 + seconds + fraction, text))
            }
        }

        guard entries.count >= 2 else { return nil }
        entries.sort { $0.0 < $1.0 }

        // Intro instrumentale : des points d'attente avant la première ligne.
        if let first = entries.first, first.0 > 4, !first.1.isEmpty {
            entries.insert((0, ""), at: 0)
        }

        // Fusionne les lignes vides qui se suivent.
        var cleaned: [(Double, String)] = []
        for e in entries {
            if e.1.isEmpty, let last = cleaned.last, last.1.isEmpty { continue }
            cleaned.append(e)
        }

        return cleaned.enumerated().map { i, e in
            LyricLine(id: i, time: max(0, e.0 - offset), text: e.1)
        }
    }

    /// Paroles sans les repères de temps (pour la recherche et l'affichage simple).
    static func plainText(_ raw: String) -> String {
        guard isSynced(raw), let lines = parse(raw) else { return raw }
        return lines.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Titre et artiste écrits dans un fichier LRC ([ti:…] et [ar:…]).
    static func tags(_ raw: String) -> (title: String?, artist: String?) {
        func value(_ key: String) -> String? {
            guard let r = raw.range(of: #"\["# + key + #":([^\]]*)\]"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
            let tag = raw[r]
            guard let colon = tag.firstIndex(of: ":") else { return nil }
            let v = tag[tag.index(after: colon)..<tag.index(before: tag.endIndex)].trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
        return (value("ti"), value("ar"))
    }
}

/// Recherche de paroles sur LRCLIB, une base libre et gratuite, uniquement quand tu la demandes.
enum LyricsService {
    private struct Result: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    static func search(title: String, artist: String, duration: Double) async -> String? {
        // Variantes : tel quel, puis titre nettoyé (« (feat. …) », « [Clip] »…) et artiste principal seulement.
        let cleanTitle = clean(title)
        let mainArtist = Self.mainArtist(artist)
        var tries = [(title, artist)]
        if cleanTitle != title || mainArtist != artist { tries.append((cleanTitle, mainArtist)) }

        for (t, a) in tries {
            if let exact = await exact(title: t, artist: a, duration: duration) { return exact }
        }
        var results: [Result] = []
        for (t, a) in tries {
            results += await query(title: t, artist: a) ?? []
        }
        // Dernier essai : recherche libre (artiste et titre ensemble).
        if results.isEmpty {
            results += await free("\(mainArtist) \(cleanTitle)") ?? []
        }
        let t = norm(cleanTitle), a = norm(mainArtist)
        // Seulement le bon morceau : même titre, même artiste (si connu).
        let same = results.filter { r in
            guard !(r.instrumental ?? false) else { return false }
            return matches(norm(r.trackName ?? ""), t) && (a.isEmpty || matches(norm(r.artistName ?? ""), a))
        }
        func gap(_ r: Result) -> Double { abs((r.duration ?? 0) - duration) }
        // Paroles synchronisées : seulement pour la même version (même durée, à 5 s près), sinon elles seraient décalées.
        let synced = same
            .filter { ($0.syncedLyrics ?? "").isEmpty == false && (duration <= 0 || gap($0) <= 5) }
            .min { gap($0) < gap($1) }
        if let s = synced?.syncedLyrics { return s }
        let plain = same.first { ($0.plainLyrics ?? "").isEmpty == false }?.plainLyrics
        return plain
    }

    /// Le titre sans « (feat. …) », « [Clip officiel] », « - Remastered »…
    static func clean(_ title: String) -> String {
        var t = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        for sep in [" feat.", " feat ", " ft.", " ft ", " - "] {
            if let r = t.range(of: sep, options: .caseInsensitive) { t = String(t[..<r.lowerBound]) }
        }
        let out = t.trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? title : out
    }

    /// Le premier artiste (« Werenoi, Ninho » → « Werenoi »).
    static func mainArtist(_ artist: String) -> String {
        var a = artist
        for sep in [",", " & ", " x ", " X ", " feat", " ft.", ";", "/"] {
            if let r = a.range(of: sep) { a = String(a[..<r.lowerBound]) }
        }
        let out = a.trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? artist : out
    }

    private static func free(_ q: String) async -> [Result]? {
        guard var c = URLComponents(string: "https://lrclib.net/api/search") else { return nil }
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        guard let url = c.url, let data = await fetch(url) else { return nil }
        return try? JSONDecoder().decode([Result].self, from: data)
    }

    /// Recherche exacte de LRCLIB (titre, artiste et durée) : la plus fiable.
    private static func exact(title: String, artist: String, duration: Double) async -> String? {
        guard !artist.isEmpty, duration > 0,
              var c = URLComponents(string: "https://lrclib.net/api/get") else { return nil }
        c.queryItems = [URLQueryItem(name: "track_name", value: title),
                        URLQueryItem(name: "artist_name", value: artist),
                        URLQueryItem(name: "duration", value: String(Int(duration.rounded())))]
        guard let url = c.url, let data = await fetch(url),
              let r = try? JSONDecoder().decode(Result.self, from: data),
              !(r.instrumental ?? false) else { return nil }
        if let d = r.duration, abs(d - duration) > 5 { return nil }
        if let s = r.syncedLyrics, !s.isEmpty { return s }
        return nil
    }

    private static func query(title: String, artist: String) async -> [Result]? {
        guard var c = URLComponents(string: "https://lrclib.net/api/search") else { return nil }
        var items = [URLQueryItem(name: "track_name", value: title)]
        if !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        c.queryItems = items
        guard let url = c.url, let data = await fetch(url) else { return nil }
        return try? JSONDecoder().decode([Result].self, from: data)
    }

    private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Platine/2.0 (lecteur personnel)", forHTTPHeaderField: "User-Agent")
        guard let (data, http) = try? await URLSession.shared.data(for: request),
              (http as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Titre ou artiste simplifié : sans accents, sans « (feat. …) », sans ponctuation.
    static func norm(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        t = t.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: " ", options: .regularExpression)
        for sep in [" feat", " ft.", " ft ", " featuring", " - "] {
            if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]) }
        }
        return t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func matches(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        return short.count >= 4 && long.contains(short)
    }
}

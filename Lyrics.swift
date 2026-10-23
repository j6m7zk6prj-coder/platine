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
        guard var components = URLComponents(string: "https://lrclib.net/api/search") else { return nil }
        var items = [URLQueryItem(name: "track_name", value: title)]
        if !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        components.queryItems = items
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Platine/2.0 (lecteur personnel)", forHTTPHeaderField: "User-Agent")

        guard let response = try? await URLSession.shared.data(for: request) else { return nil }
        let (data, http) = response
        guard (http as? HTTPURLResponse)?.statusCode == 200,
              let results = try? JSONDecoder().decode([Result].self, from: data) else { return nil }

        func score(_ r: Result) -> Double {
            var s = 0.0
            if let synced = r.syncedLyrics, !synced.isEmpty { s += 10 }
            if let d = r.duration, duration > 0 {
                let diff = abs(d - duration)
                if diff < 2 { s += 6 } else if diff < 6 { s += 3 } else if diff > 20 { s -= 8 }
            }
            if let a = r.artistName, !artist.isEmpty, a.localizedCaseInsensitiveContains(artist) { s += 2 }
            return s
        }

        let best = results
            .filter { !($0.instrumental ?? false) && (($0.syncedLyrics ?? "").isEmpty == false || ($0.plainLyrics ?? "").isEmpty == false) }
            .max { score($0) < score($1) }
        guard let best, score(best) > -5 else { return nil }
        if let synced = best.syncedLyrics, !synced.isEmpty { return synced }
        return best.plainLyrics
    }
}

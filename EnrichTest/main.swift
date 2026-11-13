import Foundation

// Test sur Mac : l'album et les paroles sont-ils bien trouvés pour de vrais morceaux ?
struct Track { var title: String; var artist: String; var album: String; var duration: Double; var lyrics: String? }
@MainActor final class Library {
    var t: Track
    init(_ t: Track) { self.t = t }
    func track(_ id: UUID) -> Track? { t }
    func fillInfo(_ id: UUID, album: String?, year: Int?, trackNumber: Int?, artist: String? = nil) {
        if let album, t.album.isEmpty { t.album = album }
        print("   année \(year ?? 0), piste \(trackNumber ?? 0)")
    }
    func setLyrics(_ id: UUID, _ text: String?) { t.lyrics = text }
}

let songs: [(String, String, Double)] = [("C63", "Werenoi", 208), ("Blinding Lights", "The Weeknd", 200),
                                         ("Bande organisée", "13 Organisé", 312), ("Basique", "Orelsan", 171)]
var bad = 0
for (title, artist, d) in songs {
    let lib = await Library(Track(title: title, artist: artist, album: "", duration: d, lyrics: nil))
    let r = await TrackEnricher.enrich(UUID(), library: lib)
    print("\(artist) - \(title) → album : \(r.album ?? "—") · paroles : \(r.lyrics)")
    if r.album == nil { bad += 1 }
}
print(bad == 0 ? "TOUT EST BON" : "\(bad) album(s) introuvable(s)")
exit(bad == 0 ? 0 : 1)

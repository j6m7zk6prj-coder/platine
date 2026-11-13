import Foundation

// Test sur Mac : l'album et les paroles sont-ils bien trouvés pour de vrais morceaux ?
struct Track {
    var title: String; var artist: String; var album: String; var duration: Double; var lyrics: String?
    var albumKey: String { artist.lowercased() + "|" + album.lowercased() }
    var displayArtist: String { artist }
}
enum ArtworkKind { case image, gif, video }
@MainActor final class Library {
    var t: Track
    init(_ t: Track) { self.t = t }
    func track(_ id: UUID) -> Track? { t }
    func fillInfo(_ id: UUID, album: String?, year: Int?, trackNumber: Int?, artist: String? = nil) {
        if let album, t.album.isEmpty { t.album = album }
        print("   année \(year ?? 0), piste \(trackNumber ?? 0)")
    }
    func setLyrics(_ id: UUID, _ text: String?) { t.lyrics = text }
    var cover = 0
    func artworkURL(_ t: Track) -> URL? { nil }
    func setAlbumCover(_ key: String, data: Data, ext: String, kind: ArtworkKind) { cover = data.count }
    func setCustomArtwork(_ ids: Set<UUID>, data: Data, ext: String, kind: ArtworkKind) { cover = data.count }
}

let songs: [(String, String, Double)] = [("C63", "Werenoi", 208), ("Moteur brûlant", "Werenoi", 0), ("Gata Only", "FloyyMenor", 0), ("Ransom", "Lil Tecca", 131), ("Blinding Lights", "The Weeknd", 200),
                                         ("Bande organisée", "13 Organisé", 312), ("Basique", "Orelsan", 171)]
var bad = 0
for (title, artist, d) in songs {
    let lib = await Library(Track(title: title, artist: artist, album: "", duration: d, lyrics: nil))
    let r = await TrackEnricher.enrich(UUID(), library: lib)
    print("\(artist) - \(title) → album : \(r.album ?? "—") · paroles : \(r.lyrics) · pochette : \(await lib.cover / 1000) Ko")
    if r.album == nil || !r.cover { bad += 1 }
}
print(bad == 0 ? "TOUT EST BON" : "\(bad) album(s) introuvable(s)")
exit(bad == 0 ? 0 : 1)

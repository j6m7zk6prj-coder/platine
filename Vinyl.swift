import SwiftUI

// MARK: - Vinyles : options, faces, prix

/// Les vinyles de la Collection ont leur propre identifiant (« vinyl: » + album) :
/// blister, stickers et personnalisation sont séparés de ceux du CD du même album.
enum VinylCatalog {
    static let prefix = "vinyl:"

    static func isVinyl(_ id: String) -> Bool { id.hasPrefix(prefix) }

    /// L'album d'origine (sans « vinyl: »).
    static func base(_ id: String) -> String { isVinyl(id) ? String(id.dropFirst(prefix.count)) : id }
}

/// Couleur (ou matière) du disque.
enum VinylColor: String, CaseIterable, Identifiable, Codable {
    case black, red, blue, green, orange, white, clear, marble, splatter, picture

    var id: String { rawValue }

    var label: String {
        switch self {
        case .black: return "Noir"
        case .red: return "Rouge"
        case .blue: return "Bleu"
        case .green: return "Vert"
        case .orange: return "Orange"
        case .white: return "Blanc"
        case .clear: return "Transparent"
        case .marble: return "Marbré"
        case .splatter: return "Éclaboussé"
        case .picture: return "Picture disc"
        }
    }

    /// Couleur de la matière (RVB, opacité).
    var base: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        switch self {
        case .black: return (0.035, 0.035, 0.04, 1)
        case .red: return (0.66, 0.04, 0.07, 0.93)
        case .blue: return (0.06, 0.22, 0.68, 0.93)
        case .green: return (0.05, 0.46, 0.22, 0.93)
        case .orange: return (0.96, 0.46, 0.06, 0.95)
        case .white: return (0.92, 0.91, 0.89, 1)
        case .clear: return (0.86, 0.87, 0.9, 0.32)
        case .marble: return (0.9, 0.88, 0.84, 1)
        case .splatter: return (0.93, 0.92, 0.9, 0.96)
        case .picture: return (0.1, 0.1, 0.1, 1)
        }
    }

    /// Pastille affichée dans le choix des couleurs.
    var swatch: [Color] {
        switch self {
        case .marble: return [Color(white: 0.92), Color(red: 0.2, green: 0.25, blue: 0.5), Color(white: 0.75)]
        case .splatter: return [Color(white: 0.94), Color(red: 0.85, green: 0.1, blue: 0.2), Color(white: 0.1)]
        case .picture: return [Color.pink, Color.purple, Color.orange]
        case .clear: return [Color.white.opacity(0.35), Color.white.opacity(0.15)]
        default:
            let c = base
            return [Color(red: c.r, green: c.g, blue: c.b)]
        }
    }

    var isTranslucent: Bool { base.a < 0.99 }
}

enum SleeveKind: String, CaseIterable, Identifiable, Codable {
    case paper, plastic
    var id: String { rawValue }
    var label: String { self == .paper ? "Papier" : "Plastique" }
}

enum JacketFinish: String, CaseIterable, Identifiable, Codable {
    case matte, glossy
    var id: String { rawValue }
    var label: String { self == .matte ? "Mat" : "Brillant" }
}

enum DiscCount: String, CaseIterable, Identifiable, Codable {
    case auto, single, double
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .single: return "1 disque"
        case .double: return "2 disques"
        }
    }
}

/// Comment les vinyles sont rangés dans la Collection.
enum VinylStorage: String, CaseIterable, Identifiable {
    case crate, wall
    var id: String { rawValue }
    var label: String { self == .crate ? "Bac à feuilleter" : "Étagère murale" }
}

/// Où en est le vinyle tenu en main.
enum VinylStage: Equatable {
    /// Dans sa pochette.
    case jacket
    /// Sorti, à moitié dans sa sous-pochette.
    case out
}

/// Réglages d'un vinyle (gardés pour chaque album).
struct VinylOptions: Codable, Equatable {
    var color: VinylColor = .black
    var sleeve: SleeveKind = .paper
    var finish: JacketFinish = .matte
    var gatefold = false
    var discs: DiscCount = .auto
    /// Sticker rond collé sur le blister (« Inclut le single… »).
    var hype = true
    /// Texte du sticker ; vide = automatique.
    var hypeText = ""

    init() {}

    enum CodingKeys: String, CodingKey { case color, sleeve, finish, gatefold, discs, hype, hypeText }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = (try? c.decodeIfPresent(VinylColor.self, forKey: .color)) ?? .black
        sleeve = (try? c.decodeIfPresent(SleeveKind.self, forKey: .sleeve)) ?? .paper
        finish = (try? c.decodeIfPresent(JacketFinish.self, forKey: .finish)) ?? .matte
        gatefold = (try? c.decodeIfPresent(Bool.self, forKey: .gatefold)) ?? false
        discs = (try? c.decodeIfPresent(DiscCount.self, forKey: .discs)) ?? .auto
        hype = (try? c.decodeIfPresent(Bool.self, forKey: .hype)) ?? true
        hypeText = (try? c.decodeIfPresent(String.self, forKey: .hypeText)) ?? ""
    }

    /// Sert à savoir quand reconstruire le modèle 3D.
    var signature: String {
        [color.rawValue, sleeve.rawValue, finish.rawValue, gatefold ? "g" : "s", discs.rawValue, hype ? "h" : "-", hypeText]
            .joined(separator: ",")
    }
}

/// Une face du disque : A, B (et C, D pour un double vinyle).
struct VinylSide {
    let letter: String
    let tracks: [Track]
    var duration: Double { tracks.reduce(0) { $0 + $1.duration } }
}

enum VinylLayout {
    /// Au-delà de 46 minutes, l'album tient sur deux disques (comme les vrais pressages).
    static func discCount(_ album: AlbumInfo, _ options: VinylOptions) -> Int {
        switch options.discs {
        case .single: return 1
        case .double: return 2
        case .auto: return album.duration > 46 * 60 ? 2 : 1
        }
    }

    /// Les morceaux répartis sur les faces, en équilibrant la durée de chacune.
    static func sides(_ album: AlbumInfo, discs: Int) -> [VinylSide] {
        let count = max(1, discs) * 2
        let letters = ["A", "B", "C", "D"]
        let total = max(1, album.duration)
        var groups: [[Track]] = Array(repeating: [], count: count)
        var elapsed = 0.0
        var side = 0
        for (i, t) in album.tracks.enumerated() {
            // Toujours au moins un morceau par face tant qu'il en reste assez.
            let remainingTracks = album.tracks.count - i
            let remainingSides = count - side - 1
            if side < count - 1, !groups[side].isEmpty,
               elapsed + t.duration / 2 > total * Double(side + 1) / Double(count) || remainingTracks <= remainingSides {
                side += 1
            }
            groups[side].append(t)
            elapsed += t.duration
        }
        return groups.enumerated().map { VinylSide(letter: letters[$0.offset], tracks: $0.element) }
    }

    /// Face en cours et avancée du bras (0 au bord du disque, 1 à la fin de la face).
    static func armState(_ sides: [VinylSide], currentID: UUID?, time: Double) -> (side: Int, progress: Double)? {
        guard let currentID else { return nil }
        for (s, side) in sides.enumerated() {
            var before = 0.0
            for t in side.tracks {
                if t.id == currentID {
                    let p = (before + min(max(0, time), t.duration)) / max(1, side.duration)
                    return (s, min(1, max(0, p)))
                }
                before += t.duration
            }
        }
        return nil
    }
}

// MARK: - Prix

enum PriceTag {
    /// Empreinte stable (la même à chaque lancement, contrairement à hashValue).
    static func stableHash(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        return hash
    }

    /// Un prix comme en magasin, toujours le même pour un album donné : les nouveautés sont plus chères,
    /// les albums plus anciens passent en « prix découverte ».
    static func defaultPrice(album: AlbumInfo, vinyl: Bool, discs: Int) -> Double {
        let now = Calendar.current.component(.year, from: Date())
        let age = album.year > 0 ? now - album.year : 8
        let list: [Double]
        if vinyl {
            if age <= 1 { list = [27.99, 29.99, 31.99, 34.99] }
            else if age <= 8 { list = [24.99, 26.99, 27.99, 29.99] }
            else { list = [19.99, 22.99, 24.99, 25.99] }
        } else {
            if age <= 1 { list = [14.99, 15.99, 16.99, 17.99] }
            else if age <= 8 { list = [11.99, 12.99, 13.99, 14.99] }
            else { list = [7.99, 8.99, 9.99, 10.99] }
        }
        let base = list[Int(stableHash(VinylCatalog.base(album.id)) % UInt64(list.count))]
        return vinyl && discs > 1 ? base + 10 : base
    }

    /// Environ un album sur cinq est en promotion (ancien prix barré, comme en magasin).
    static func promo(album: AlbumInfo, price: Double) -> Double? {
        let h = stableHash("promo|" + VinylCatalog.base(album.id))
        guard h % 5 == 0 else { return nil }
        // Remise de 20 à 30 %, arrondie en ,99 comme sur les étiquettes.
        let rate = [0.2, 0.25, 0.3][Int((h / 5) % 3)]
        let cut = (price * (1 - rate)).rounded(.down) + 0.99
        return cut < price - 1 ? cut : nil
    }

    static func text(_ price: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return (f.string(from: NSNumber(value: price)) ?? String(format: "%.2f", price)) + " €"
    }
}

/// Ce qui est imprimé sur l'étiquette prix.
struct PriceLabel {
    let price: Double
    /// Ancien prix barré (promotion).
    let was: Double?
    let vinyl: Bool
    let seed: UInt64

    var key: String { PriceTag.text(price) + "|" + (was.map(PriceTag.text) ?? "-") + (vinyl ? "|lp" : "|cd") }
    /// Référence interne du magasin, comme sur les vraies étiquettes.
    var reference: String { String(format: "%06d", Int(seed % 1_000_000)) }
}

// MARK: - Bibliothèque

extension Library {
    /// Les albums rangés dans le bac à vinyles.
    var vinylAlbums: [AlbumInfo] {
        albums.filter { isVinylExposed($0.id) }.map { a in
            AlbumInfo(id: VinylCatalog.prefix + a.id, title: a.title, artist: a.artist, year: a.year,
                      tracks: a.tracks, coverTrack: a.coverTrack)
        }
    }

    func vinylOptions(_ albumID: String) -> VinylOptions {
        vinylOptionsMap[VinylCatalog.base(albumID)] ?? VinylOptions()
    }

    /// Prix normal (le tien si tu l'as changé).
    func price(for album: AlbumInfo, discs: Int = 1) -> Double {
        customPrices[album.id] ?? PriceTag.defaultPrice(album: album, vinyl: VinylCatalog.isVinyl(album.id), discs: discs)
    }

    /// L'étiquette : prix affiché, et ancien prix barré si l'album est en promotion.
    func priceLabel(for album: AlbumInfo, discs: Int = 1) -> PriceLabel {
        let normal = price(for: album, discs: discs)
        if customPrices[album.id] == nil, let promo = PriceTag.promo(album: album, price: normal) {
            return PriceLabel(price: promo, was: normal, vinyl: VinylCatalog.isVinyl(album.id), seed: PriceTag.stableHash(album.id))
        }
        return PriceLabel(price: normal, was: nil, vinyl: VinylCatalog.isVinyl(album.id), seed: PriceTag.stableHash(album.id))
    }

    func hasCustomPrice(_ albumID: String) -> Bool { customPrices[albumID] != nil }

    /// Usure du cercle du disque sur la pochette (0 à 1) : plus l'album est écouté, plus elle se voit.
    func ringWear(_ album: AlbumInfo) -> Double {
        let plays = album.tracks.reduce(0) { $0 + $1.playCount }
        return min(1, Double(plays) / Double(max(1, album.tracks.count) * 6))
    }
}

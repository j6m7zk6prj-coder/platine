import SwiftUI

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
        let base = list[Int(stableHash(album.id) % UInt64(list.count))]
        return vinyl && discs > 1 ? base + 10 : base
    }

    /// Environ un album sur cinq est en promotion (ancien prix barré, comme en magasin).
    static func promo(album: AlbumInfo, price: Double) -> Double? {
        let h = stableHash("promo|" + album.id)
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
    /// Prix normal (le tien si tu l'as changé).
    func price(for album: AlbumInfo, discs: Int = 1) -> Double {
        customPrices[album.id] ?? PriceTag.defaultPrice(album: album, vinyl: false, discs: discs)
    }

    /// L'étiquette : prix affiché, et ancien prix barré si l'album est en promotion.
    func priceLabel(for album: AlbumInfo, discs: Int = 1) -> PriceLabel {
        let normal = price(for: album, discs: discs)
        if customPrices[album.id] == nil, let promo = PriceTag.promo(album: album, price: normal) {
            return PriceLabel(price: promo, was: normal, vinyl: false, seed: PriceTag.stableHash(album.id))
        }
        return PriceLabel(price: normal, was: nil, vinyl: false, seed: PriceTag.stableHash(album.id))
    }

    func hasCustomPrice(_ albumID: String) -> Bool { customPrices[albumID] != nil }

}

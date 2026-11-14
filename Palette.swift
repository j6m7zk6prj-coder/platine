import SwiftUI
import UIKit

/// Extrait trois couleurs d'une pochette pour teinter le fond.
enum Palette {
    static let defaults: [Color] = [
        Color(hue: 0.68, saturation: 0.25, brightness: 0.16),
        Color(hue: 0.72, saturation: 0.45, brightness: 0.48),
        Color(hue: 0.55, saturation: 0.45, brightness: 0.42)
    ]

    private struct HSB {
        var h: CGFloat
        var s: CGFloat
        var b: CGFloat
    }

    /// Les vraies couleurs de la pochette : on regroupe les pixels par teinte (24 familles),
    /// on garde celles qui couvrent le plus de surface, et on prend la couleur moyenne de chaque
    /// famille — pas la moyenne de toute l'image, qui donne un gris-marron qui ne ressemble à rien.
    static func colors(from image: UIImage) -> [Color] {
        guard let cg = image.cgImage else { return defaults }
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return defaults }

        struct Bin { var weight: CGFloat = 0; var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var count = 0 }
        let binCount = 24
        var bins = [Bin](repeating: Bin(), count: binCount)
        var all = Bin()
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = CGFloat(pixels[i]) / 255, g = CGFloat(pixels[i + 1]) / 255, b = CGFloat(pixels[i + 2]) / 255
            all.r += r; all.g += g; all.b += b; all.count += 1
            let c = hsb(r, g, b)
            // Les gris, les noirs et les blancs ne votent pas pour une teinte.
            guard c.s > 0.18, c.b > 0.14 else { continue }
            let k = min(binCount - 1, Int(c.h * CGFloat(binCount)))
            // Une couleur franche et bien visible compte plus qu'une teinte délavée.
            let w = c.s * (0.35 + 0.65 * min(1, c.b * 1.4))
            bins[k].weight += w
            bins[k].r += r * w; bins[k].g += g * w; bins[k].b += b * w
            bins[k].count += 1
        }
        let total = CGFloat(side * side)
        let avg = hsb(all.r / CGFloat(max(1, all.count)), all.g / CGFloat(max(1, all.count)), all.b / CGFloat(max(1, all.count)))

        // Chaque famille absorbe ses voisines immédiates, pour ne pas couper une couleur en deux.
        var merged = bins
        for k in 0..<binCount {
            let l = bins[(k + binCount - 1) % binCount], rr = bins[(k + 1) % binCount]
            merged[k].weight = bins[k].weight + 0.5 * (l.weight + rr.weight)
        }
        func color(of k: Int) -> HSB? {
            let x = bins[k]
            guard x.weight > 0 else { return nil }
            return hsb(x.r / x.weight, x.g / x.weight, x.b / x.weight)
        }
        let ranked = (0..<binCount).filter { bins[$0].count > 0 }.sorted { merged[$0].weight > merged[$1].weight }

        // Pochette en noir et blanc (ou presque) : un fond neutre, sans couleur inventée.
        let colorfulShare = CGFloat(bins.reduce(0) { $0 + $1.count }) / total
        guard colorfulShare > 0.04, let k1 = ranked.first, let main = color(of: k1) else {
            let light = min(0.55, max(0.3, avg.b * 0.9 + 0.18))
            return [
                Color(white: 0.09),
                Color(hue: Double(avg.h), saturation: Double(min(0.08, avg.s)), brightness: Double(light)),
                Color(hue: Double(avg.h), saturation: Double(min(0.06, avg.s)), brightness: Double(light * 0.7))
            ]
        }
        // Deuxième couleur : une autre famille bien présente ; sinon une variante de la première.
        let k2 = ranked.first { k in
            let d = min(abs(k - k1), binCount - abs(k - k1))
            return d >= 3 && merged[k].weight > merged[k1].weight * 0.18
        }
        let second = k2.flatMap(color(of:)) ?? HSB(h: main.h, s: main.s * 0.8, b: main.b * 0.7)

        // Peu de couleur sur la pochette : des teintes plus retenues.
        let vivid = min(1, 0.55 + colorfulShare)
        func tone(_ c: HSB, _ lo: CGFloat, _ hi: CGFloat) -> Color {
            Color(hue: Double(c.h),
                  saturation: Double(min(0.9, c.s * 1.1 * vivid)),
                  brightness: Double(min(hi, max(lo, c.b))))
        }
        return [
            // Le fond : la couleur principale, très assombrie (au lieu de la moyenne de l'image).
            Color(hue: Double(main.h), saturation: Double(min(0.75, main.s * 0.9 * vivid)), brightness: 0.17),
            tone(main, 0.42, 0.82),
            tone(second, 0.34, 0.72)
        ]
    }

    /// Note de « vie » d'une image : lumineuse et colorée = élevée, noire = proche de 0.
    static func liveliness(of image: UIImage) -> CGFloat {
        guard let cg = image.cgImage else { return 0 }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return 0 }
        var total: CGFloat = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let c = hsb(CGFloat(pixels[i]) / 255, CGFloat(pixels[i + 1]) / 255, CGFloat(pixels[i + 2]) / 255)
            total += c.b * (0.6 + c.s * 0.4)
        }
        return total / CGFloat(side * side)
    }

    private static func hsb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> HSB {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return HSB(h: h, s: s, b: v)
    }

    private static func hueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let d = abs(a - b)
        return min(d, 1 - d)
    }
}

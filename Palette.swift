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

    static func colors(from image: UIImage) -> [Color] {
        guard let cg = image.cgImage else { return defaults }
        let side = 8
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

        var list: [HSB] = []
        var sumR: CGFloat = 0, sumG: CGFloat = 0, sumB: CGFloat = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = CGFloat(pixels[i]) / 255, g = CGFloat(pixels[i + 1]) / 255, b = CGFloat(pixels[i + 2]) / 255
            sumR += r; sumG += g; sumB += b
            list.append(hsb(r, g, b))
        }
        let n = CGFloat(side * side)
        let avg = hsb(sumR / n, sumG / n, sumB / n)

        func score(_ c: HSB) -> CGFloat { c.s * (1 - abs(c.b - 0.6)) }
        let sorted = list.sorted { score($0) > score($1) }
        let first = sorted.first ?? avg

        // Pochette en noir et blanc (ou presque) : un fond neutre, sans couleur inventée.
        let colorful = list.filter { $0.s > 0.22 && $0.b > 0.18 }.count
        if colorful < 3 {
            let light = min(0.55, max(0.3, avg.b * 0.9 + 0.18))
            return [
                Color(white: 0.09),
                Color(hue: Double(avg.h), saturation: Double(min(0.1, avg.s)), brightness: Double(light)),
                Color(hue: Double(avg.h), saturation: Double(min(0.08, avg.s)), brightness: Double(light * 0.7))
            ]
        }
        let second = sorted.first(where: { hueDistance($0.h, first.h) > 0.08 && $0.s > 0.15 }) ?? avg

        func tone(_ c: HSB) -> Color {
            Color(hue: Double(c.h),
                  saturation: Double(min(0.85, c.s * 1.25 + 0.05)),
                  brightness: Double(min(0.8, max(0.42, c.b))))
        }
        return [
            Color(hue: Double(avg.h), saturation: Double(min(0.7, avg.s * 1.2)), brightness: 0.2),
            tone(first),
            tone(second)
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

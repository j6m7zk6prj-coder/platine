import SwiftUI
import SceneKit
import UIKit

// MARK: - Étiquettes prix des CD

extension AlbumNodeBuilder {
    /// Étiquette prix collée, sortie de l'étiqueteuse du magasin.
    static func priceTagNode(_ label: PriceLabel, width: CGFloat) -> SCNNode {
        let key = "price3|" + label.key + "|" + label.reference
        let image: UIImage
        if let img = textures.object(forKey: key as NSString) { image = img } else {
            image = PriceStickerArt.priceSticker(label)
            textures.setObject(image, forKey: key as NSString)
        }
        // `width` = largeur d'une étiquette ; une promo en a deux (la nouvelle collée par-dessus l'ancienne).
        let k = width / 1024
        let plane = SCNPlane(width: image.size.width * k, height: image.size.height * k)
        let m = printed(image)
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.renderingOrder = 14
        return node
    }
}

@MainActor
enum PriceStickerArt {
    private static func renderer(_ size: CGSize, opaque: Bool = false) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format)
    }

    /// Étiquette prix sortie d'une étiqueteuse de magasin (la « pince à prix ») : petit rectangle
    /// de papier aux coins arrondis, bandeau pré-imprimé en rouge, prix frappé à l'encre violette un peu
    /// irrégulière (lettres légèrement décalées, encre plus pâle par endroits) et les deux petites
    /// entailles de sécurité. Promo : une étiquette orange fluo collée de travers sur l'ancienne.
    static func priceSticker(_ label: PriceLabel) -> UIImage {
        let lw: CGFloat = 1024, lh: CGFloat = 630
        let canvas = label.was == nil ? CGSize(width: lw, height: lh) : CGSize(width: lw + 300, height: lh + 250)
        var rng = SeededRandom(seed: label.seed)
        // Papier : surtout blanc ; parfois jaune ou orange fluo, comme les rouleaux des magasins.
        let papers: [UIColor] = [UIColor(white: 0.975, alpha: 1), UIColor(white: 0.975, alpha: 1), UIColor(white: 0.975, alpha: 1),
                                 UIColor(red: 1, green: 0.95, blue: 0.45, alpha: 1)]
        let paper = papers[Int(label.seed % UInt64(papers.count))]
        let fluo = UIColor(red: 1, green: 0.55, blue: 0.16, alpha: 1)
        let code = (label.vinyl ? "LP " : "CD ") + label.reference

        return renderer(canvas).image { ctx in
            let c = ctx.cgContext
            if let was = label.was {
                // L'ancienne étiquette dessous, la nouvelle collée par-dessus, un peu de travers.
                drawGunLabel(c, at: CGPoint(x: 20, y: 20), size: CGSize(width: lw - 40, height: lh - 40), angle: -0.02,
                             paper: UIColor(white: 0.975, alpha: 1), price: was, code: code, header: "PLATINE DISQUES", rng: &rng)
                drawGunLabel(c, at: CGPoint(x: 280, y: 230), size: CGSize(width: lw - 40, height: lh - 40), angle: 0.035,
                             paper: fluo, price: label.price, code: "PROMO", header: "PRIX CHOC", rng: &rng)
            } else {
                drawGunLabel(c, at: CGPoint(x: 20, y: 20), size: CGSize(width: lw - 40, height: lh - 40), angle: 0,
                             paper: paper, price: label.price, code: code, header: "PLATINE DISQUES", rng: &rng)
            }
        }
    }

    private static func drawGunLabel(_ c: CGContext, at origin: CGPoint, size: CGSize, angle: CGFloat,
                                     paper: UIColor, price: Double, code: String, header: String, rng: inout SeededRandom) {
        c.saveGState()
        c.translateBy(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        c.rotate(by: angle)
        c.translateBy(x: -size.width / 2, y: -size.height / 2)
        let rect = CGRect(origin: .zero, size: size)
        let shape = UIBezierPath(roundedRect: rect, cornerRadius: size.height * 0.1)

        // Le papier, avec une ombre très fine (il est collé, à peine relevé sur un bord).
        c.setShadow(offset: CGSize(width: 0, height: 4), blur: 8, color: UIColor(white: 0, alpha: 0.32).cgColor)
        c.setFillColor(paper.cgColor)
        c.addPath(shape.cgPath)
        c.fillPath()
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.saveGState()
        c.addPath(shape.cgPath)
        c.clip()

        // Fibres du papier.
        for _ in 0..<500 {
            c.setFillColor(UIColor(white: rng.next(0, 1) > 0.5 ? 1 : 0, alpha: CGFloat(rng.next(0.015, 0.05))).cgColor)
            c.fill(CGRect(x: rng.next(0, Double(size.width)), y: rng.next(0, Double(size.height)),
                          width: rng.next(1, 5), height: rng.next(0.6, 1.6)))
        }

        // Bandeau pré-imprimé (rouge) : nom du magasin entre deux filets.
        let pre = UIColor(red: 0.85, green: 0.1, blue: 0.14, alpha: 0.92)
        c.setFillColor(pre.cgColor)
        c.fill(CGRect(x: 0, y: size.height * 0.07, width: size.width, height: 5))
        c.fill(CGRect(x: 0, y: size.height * 0.25, width: size.width, height: 5))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        NSAttributedString(string: header, attributes: [
            .font: UIFont.systemFont(ofSize: size.height * 0.11, weight: .heavy), .foregroundColor: pre,
            .kern: size.height * 0.02, .paragraphStyle: style
        ]).draw(in: CGRect(x: 0, y: size.height * 0.095, width: size.width, height: size.height * 0.15))

        // Encre de l'étiqueteuse : violet foncé, caractères frappés un à un.
        let ink = UIColor(red: 0.2, green: 0.08, blue: 0.32, alpha: 1)
        func stamp(_ text: String, x: CGFloat, baseline: CGFloat, height: CGFloat, spacing: CGFloat) -> CGFloat {
            let font = UIFont.monospacedDigitSystemFont(ofSize: height, weight: .heavy)
            var cx = x
            for ch in text {
                let alpha = CGFloat(rng.next(0.72, 0.95))
                let a = NSAttributedString(string: String(ch), attributes: [
                    .font: font, .foregroundColor: ink.withAlphaComponent(alpha)
                ])
                let s = a.size()
                let dy = CGFloat(rng.next(-2.5, 2.5))
                c.saveGState()
                // Caractères étroits et hauts, comme sur les molettes d'une étiqueteuse.
                c.translateBy(x: cx, y: baseline - s.height + dy)
                c.scaleBy(x: 0.8, y: 1)
                a.draw(at: .zero)
                // Frappe doublée à peine décalée : l'encre bave un peu.
                NSAttributedString(string: String(ch), attributes: [
                    .font: font, .foregroundColor: ink.withAlphaComponent(alpha * 0.25)
                ]).draw(at: CGPoint(x: 1.6, y: 1.2))
                c.restoreGState()
                cx += s.width * 0.8 + spacing
            }
            return cx
        }
        // Le prix : « 14,99 € », centré.
        let text = PriceTag.text(price).replacingOccurrences(of: " €", with: "")
        let digitH = size.height * 0.46
        let probe = NSAttributedString(string: text, attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: digitH, weight: .heavy)])
        let euroH = digitH * 0.55
        let total = probe.size().width * 0.8 + CGFloat(text.count) * 4 + euroH * 0.75
        var x = (size.width - total) / 2 + CGFloat(rng.next(-10, 10))
        let baseline = size.height * 0.8 + CGFloat(rng.next(-4, 4))
        x = stamp(text, x: x, baseline: baseline, height: digitH, spacing: 4)
        _ = stamp("€", x: x + 6, baseline: baseline - digitH * 0.05, height: euroH, spacing: 0)
        // Petite ligne de code en bas (rayon et référence).
        let codeAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: size.height * 0.075, weight: .bold),
            .foregroundColor: ink.withAlphaComponent(0.7), .kern: 3
        ]
        NSAttributedString(string: code, attributes: codeAttrs).draw(at: CGPoint(x: size.width * 0.07, y: size.height * 0.86))

        // Encre manquante par endroits (petits points couleur papier sur la frappe).
        for _ in 0..<260 {
            let px = rng.next(0, Double(size.width)), py = rng.next(Double(size.height * 0.3), Double(size.height * 0.95))
            let r = rng.next(1, 3.5)
            c.setFillColor(paper.withAlphaComponent(CGFloat(rng.next(0.4, 0.9))).cgColor)
            c.fillEllipse(in: CGRect(x: px, y: py, width: r, height: r))
        }
        c.restoreGState()

        // Les deux entailles de sécurité (l'étiquette se déchire si on essaie de la décoller).
        c.setBlendMode(.clear)
        c.setLineWidth(4)
        c.setLineCap(.round)
        for side in [0.0, 1.0] {
            let cx = side == 0 ? size.width * 0.09 : size.width * 0.91
            let cy = size.height * 0.62
            c.addArc(center: CGPoint(x: cx, y: cy), radius: size.height * 0.07,
                     startAngle: side == 0 ? .pi * 0.6 : .pi * 1.6, endAngle: side == 0 ? .pi * 1.4 : .pi * 0.4, clockwise: false)
            c.strokePath()
        }
        c.setBlendMode(.normal)
        // Reflet discret du papier glacé.
        c.addPath(shape.cgPath)
        c.clip()
        let gloss = [UIColor(white: 1, alpha: 0.22).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: gloss, locations: [0, 1]) {
            c.drawLinearGradient(grad, start: .zero, end: CGPoint(x: size.width * 0.5, y: size.height), options: [])
        }
        c.restoreGState()
    }

}

/// Le prix écrit sur l'étiquette du disquaire.
struct PriceSection: View {
    let album: AlbumInfo
    var discs = 1
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var draft = ""

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Étiquettes prix", isOn: $settings.priceStickers)
            if settings.priceStickers {
                HStack {
                    Text("Prix")
                    Spacer()
                    TextField(PriceTag.text(library.price(for: album, discs: discs)), text: $draft)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                        .onSubmit { save() }
                    Text("€").foregroundStyle(.secondary)
                }
                if library.hasCustomPrice(album.id) {
                    Button("Prix proposé par Platine") {
                        draft = ""
                        library.setPrice(nil, for: album.id)
                    }
                }
                Button("Appliquer ce prix") { save() }
                    .disabled(draft.isEmpty)
            }
        } header: {
            Text("Étiquette prix")
        } footer: {
            Text("Collée sur le boîtier ou la pochette, comme en magasin. Certains albums sont en promotion (ancien prix barré) tant que tu ne changes pas leur prix.")
        }
        .onAppear {
            if library.hasCustomPrice(album.id) {
                draft = String(format: "%.2f", library.price(for: album, discs: discs)).replacingOccurrences(of: ".", with: ",")
            }
        }
    }

    private func save() {
        let clean = draft.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "€", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(clean), value > 0, value < 10_000 else { return }
        library.setPrice(value, for: album.id)
    }
}

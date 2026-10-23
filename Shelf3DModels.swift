import SwiftUI
import SceneKit
import UIKit

// MARK: - Dimensions réelles (en unités de scène)

enum Physical {
    /// Boîtier CD : 142 × 125 × 10 mm. Cassette : 100 × 63 × 12 mm (agrandie à la largeur du CD).
    /// Boîtier de jeu PS5 : 135 × 170 × 14 mm.
    static func size(_ format: AlbumFormat) -> SCNVector3 {
        switch format {
        case .cd: return SCNVector3(1.42, 1.25, 0.1)
        case .cassette: return SCNVector3(1.42, 0.899, 0.17)
        case .game: return SCNVector3(1.35, 1.7, 0.14)
        }
    }

    /// Profondeur du disque rangé dans le boîtier de jeu (posé sur le plateau).
    static let gameDiscZ: Float = -0.023
}

// MARK: - Un album en 3D

final class AlbumNode {
    let albumID: String
    let format: AlbumFormat
    let signature: String
    /// Placé par la mise en page (carrousel ou vue en main).
    let root = SCNNode()
    /// L'objet lui-même (boîtier ou cassette), qui peut glisser quand le CD sort.
    let body = SCNNode()
    private(set) var discPivot: SCNNode?
    let reels: [SCNNode]
    /// Couvercle du boîtier de jeu, qui s'ouvre comme un livre.
    let lidPivot: SCNNode?
    private(set) var spinning = false
    private(set) var discOut = false

    var size: SCNVector3 { Physical.size(format) }

    init(albumID: String, format: AlbumFormat, signature: String, parts: [SCNNode], discPivot: SCNNode?, reels: [SCNNode],
         lidPivot: SCNNode? = nil) {
        self.albumID = albumID
        self.format = format
        self.signature = signature
        self.discPivot = discPivot
        self.reels = reels
        self.lidPivot = lidPivot
        root.addChildNode(body)
        for p in parts {
            body.addChildNode(p)
            // Les pièces transparentes ne sont pas recalculées dans le reflet du sol (plus fluide).
            if p.renderingOrder >= 9 { p.categoryBitMask = 2 }
        }
        if let discPivot {
            discPivot.position = restDisc
            root.addChildNode(discPivot)
        }
        for r in reels { body.addChildNode(r) }
    }

    private var restDisc: SCNVector3 {
        format == .game ? SCNVector3(0, 0.02, Physical.gameDiscZ) : SCNVector3(0.05, 0, 0)
    }
    private var outDisc: SCNVector3 {
        format == .game ? SCNVector3(0, 1.0, Physical.gameDiscZ + 0.14) : SCNVector3(0.05, 0.72, 0.02)
    }
    private var outBody: SCNVector3 {
        format == .game ? SCNVector3(0, -0.45, 0) : SCNVector3(0, -0.32, 0)
    }

    /// Le disque n'est fabriqué qu'au besoin (ouverture plus rapide).
    var hasDisc: Bool { discPivot != nil }

    func attachDisc(_ pivot: SCNNode) {
        guard discPivot == nil else { return }
        discPivot = pivot
        pivot.position = restDisc
        root.addChildNode(pivot)
        if spinning {
            pivot.runAction(.repeatForever(.rotateBy(x: 0, y: 0, z: -2 * .pi, duration: 1.8)), forKey: "spin")
        }
    }

    /// Remet l'objet au repos sans animation.
    func settle() {
        discOut = false
        lidPivot?.eulerAngles = SCNVector3(0, 0, 0)
        guard let discPivot else { return }
        discPivot.position = restDisc
        discPivot.opacity = 0
        body.position = SCNVector3(0, 0, 0)
    }

    func setSpinning(_ on: Bool) {
        guard on != spinning else { return }
        spinning = on
        let spinners = reels + (discPivot.map { [$0] } ?? [])
        for node in spinners {
            if on {
                let duration = node === discPivot ? 1.8 : 2.4
                node.runAction(.repeatForever(.rotateBy(x: 0, y: 0, z: -2 * .pi, duration: duration)), forKey: "spin")
            } else {
                node.removeAction(forKey: "spin")
            }
        }
    }

    /// Le CD sort par le haut du boîtier, comme quand on le retire à la main.
    func setDiscOut(_ out: Bool, animated: Bool = true) {
        guard let discPivot, out != discOut else { return }
        discOut = out
        if let lidPivot {
            // Boîtier de jeu : le couvercle s'ouvre d'abord, puis le disque se soulève.
            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.55 : 0
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.8, 0.3, 1)
            lidPivot.eulerAngles = out ? SCNVector3(0, -2.45, 0) : SCNVector3(0, 0, 0)
            if out { discPivot.opacity = 1 }
            SCNTransaction.commit()
            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.7 : 0
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1)
            discPivot.position = out ? outDisc : restDisc
            body.position = out ? outBody : SCNVector3(0, 0, 0)
            SCNTransaction.completionBlock = { [weak self] in
                if self?.discOut == false { discPivot.opacity = 0 }
            }
            SCNTransaction.commit()
            return
        }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.7 : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1)
        discPivot.position = out ? SCNVector3(0.05, 0.72, 0.02) : SCNVector3(0.05, 0, 0)
        discPivot.opacity = out ? 1 : 0
        body.position = out ? SCNVector3(0, -0.32, 0) : SCNVector3(0, 0, 0)
        SCNTransaction.commit()
    }
}

// MARK: - Fabrication des modèles

/// Dessine les faces avec les vues 2D, puis assemble les pièces en volume.
@MainActor
struct AlbumNodeBuilder {
    let library: Library
    let settings: AppSettings

    func signature(_ album: AlbumInfo, _ format: AlbumFormat, _ badges: [AlbumBadge]) -> String {
        var art = library.artworkURL(album.first)?.lastPathComponent ?? "-"
        if let game = library.gameName(album.id) {
            // Bande-son : la jaquette choisie et la liste des morceaux (dos du boîtier).
            art = (library.gameCoverName(game) ?? "auto") + "#" + String(album.tracks.count)
                + "#" + (album.tracks.last?.id.uuidString ?? "")
        }
        return [album.id, format.rawValue, art, badges.map(\.rawValue).joined(separator: ","), album.title, album.artist].joined(separator: "|")
    }

    func make(_ album: AlbumInfo, format: AlbumFormat, badges: [AlbumBadge], extras: Bool) -> AlbumNode {
        let sig = signature(album, format, badges)
        switch format {
        case .cd: return makeCD(album, badges: badges, extras: extras, signature: sig)
        case .cassette: return makeCassette(album, badges: badges, signature: sig)
        case .game: return makeGameCase(album, badges: badges, extras: extras, signature: sig)
        }
    }

    // MARK: Boîtier CD : plateau fumé, pochette glissée sous un couvercle cristal, charnière.

    private func makeCD(_ album: AlbumInfo, badges: [AlbumBadge], extras: Bool, signature: String) -> AlbumNode {
        let size = Physical.size(.cd)
        let W = CGFloat(size.x), H = CGFloat(size.y), D = CGFloat(size.z)
        var parts: [SCNNode] = []

        // Plateau : noir fumé, le dos porte la jaquette arrière.
        let backImage = cached("back|" + signature) {
            render(CDBackInsert(album: album, lightX: 0), CGSize(width: 568, height: 500), scale: 2.2)
        }
        let spine = cached("spine|" + signature) {
            Self.spineImage(title: album.title, artist: album.artist, color: UIColor(library.palette(for: album.first)[0]))
        }
        let tray = SCNBox(width: W - 0.012, height: H - 0.008, length: D - 0.014, chamferRadius: 0.012)
        let smoke = Self.plastic(UIColor(white: 0.1, alpha: 1), roughness: 0.45, coat: 0.2)
        let black = Self.plastic(UIColor(white: 0.03, alpha: 1), roughness: 0.5, coat: 0.1)
        // Les tranches gauche et droite portent le dos imprimé (titre et artiste), comme un vrai boîtier.
        let spineMat = Self.printed(spine ?? UIColor.darkGray)
        tray.materials = [black, spineMat, Self.printed(backImage ?? UIColor.darkGray), spineMat, smoke, smoke]
        let trayNode = SCNNode(geometry: tray)
        trayNode.position.z = -0.007
        parts.append(trayNode)

        // Pochette : un carré de 120 mm glissé sous le couvercle, décalé vers la droite.
        let cover = SCNPlane(width: 1.2, height: 1.2)
        let coverImage = cached("cover|" + signature) {
            render(CoverFace(album: album, badges: badges), CGSize(width: 600, height: 600), scale: 2.2)
        }
        // Couleurs exactes de la pochette : elle n'est pas « brûlée » par les lumières.
        cover.materials = [Self.printed(coverImage ?? UIColor.darkGray)]
        let coverNode = SCNNode(geometry: cover)
        coverNode.position = SCNVector3(Float(W / 2 - 0.62), 0, Float(D / 2 - 0.0135))
        parts.append(coverNode)

        // Charnière : bande en plastique bleuté translucide, avec ses trois pastilles, comme un vrai boîtier.
        let hinge = SCNPlane(width: 0.19, height: H - 0.03)
        let hingeMat = SCNMaterial()
        hingeMat.lightingModel = .constant
        hingeMat.diffuse.contents = Self.hingeStrip
        hingeMat.blendMode = .alpha
        hingeMat.writesToDepthBuffer = false
        hinge.materials = [hingeMat]
        let hingeNode = SCNNode(geometry: hinge)
        hingeNode.position = SCNVector3(Float(-W / 2 + 0.012 + 0.095), 0, Float(D / 2 - 0.0125))
        hingeNode.renderingOrder = 9
        parts.append(hingeNode)

        // Couvercle en cristal : bords bien visibles (blancs translucides), face transparente
        // avec le cadre fin et la séparation de la charnière dessinés dessus.
        let lid = SCNBox(width: W, height: H, length: 0.012, chamferRadius: 0.004)
        let face = SCNMaterial()
        face.lightingModel = .constant
        face.diffuse.contents = Self.lidFace
        face.blendMode = .alpha
        face.writesToDepthBuffer = false
        let lidEdge = SCNMaterial()
        lidEdge.lightingModel = .physicallyBased
        lidEdge.diffuse.contents = UIColor(white: 0.93, alpha: 0.6)
        lidEdge.roughness.contents = 0.18
        lidEdge.blendMode = .alpha
        lidEdge.writesToDepthBuffer = false
        let inner = Self.glassy(strength: 0.3)
        lid.materials = [face, lidEdge, inner, lidEdge, lidEdge, lidEdge]
        let lidNode = SCNNode(geometry: lid)
        lidNode.position.z = Float(D / 2 - 0.006)
        lidNode.renderingOrder = 10
        parts.append(lidNode)

        // Reflets du cristal, posés juste devant (additifs : ils ne voilent jamais la pochette).
        let gloss = SCNPlane(width: W - 0.01, height: H - 0.01)
        let glossMat = Self.glassy(strength: 0.6)
        if badges.contains(.platinum) { glossMat.shaderModifiers = [.fragment: Self.iridescence] }
        gloss.materials = [glossMat]
        let glossNode = SCNNode(geometry: gloss)
        glossNode.position.z = Float(D / 2) + 0.0008
        glossNode.renderingOrder = 11
        parts.append(glossNode)

        // Petits rebords du couvercle, en haut et en bas, qui viennent s'emboîter sur le plateau.
        for y in [-1.0, 1.0] {
            let lip = SCNBox(width: W - 0.2, height: 0.012, length: D - 0.01, chamferRadius: 0.004)
            lip.materials = [lidEdge]
            let lipNode = SCNNode(geometry: lip)
            lipNode.position = SCNVector3(0.08, Float(y * Double(H / 2 - 0.006)), 0)
            lipNode.renderingOrder = 10
            parts.append(lipNode)
        }
        // Les deux charnières arrondies qui tiennent le couvercle.
        for y in [-1.0, 1.0] {
            let knuckle = SCNCylinder(radius: 0.028, height: 0.1)
            knuckle.materials = [lidEdge]
            let k = SCNNode(geometry: knuckle)
            k.position = SCNVector3(Float(-W / 2 + 0.018), Float(y * Double(H / 2 - 0.12)), Float(D / 2 - 0.02))
            k.renderingOrder = 10
            parts.append(k)
        }

        return AlbumNode(albumID: album.id, format: .cd, signature: signature, parts: parts,
                         discPivot: extras ? makeDisc(album) : nil, reels: [])
    }

    /// Le CD lui-même, rangé (invisible) dans le boîtier : un vrai disque de 120 mm,
    /// troué au centre, avec la face imprimée d'un côté et la face miroir irisée de l'autre.
    func makeDisc(_ album: AlbumInfo) -> SCNNode {
        let label: UIImage?
        if let game = library.gameName(album.id) {
            label = cached("gamedisc|" + game + "|" + (library.gameCoverName(game) ?? "auto")) {
                Self.gameDiscLabel(self.gameCover(album, game: game), title: game)
            }
        } else {
            label = cached("disclabel|" + album.id + "|" + (library.artworkURL(album.first)?.lastPathComponent ?? "-")) {
                Self.discLabel(library.image(for: album.first))
            }
        }
        // Face imprimée : couleurs fidèles, avec un léger vernis.
        let front = SCNMaterial()
        front.lightingModel = .constant
        front.diffuse.contents = label
        front.multiply.contents = UIColor(white: 0.95, alpha: 1)
        front.blendMode = .alpha
        front.writesToDepthBuffer = true

        // Face gravée : miroir argenté, reflet en « nœud papillon » et arcs-en-ciel qui tournent avec l'angle.
        let matrix = Self.matrixCode(album)
        let dataSide = cached("discback|" + album.id + "|" + album.title) {
            Self.discDataSide(matrix: matrix)
        }
        let back = SCNMaterial()
        back.lightingModel = .constant
        back.diffuse.contents = dataSide
        back.blendMode = .alpha
        back.shaderModifiers = [.fragment: Self.diffraction]

        let rim = SCNMaterial()
        rim.lightingModel = .physicallyBased
        rim.diffuse.contents = UIColor(white: 0.8, alpha: 0.55)
        rim.roughness.contents = 0.2
        rim.writesToDepthBuffer = false

        let geometry = Self.discGeometry(outer: 0.6, inner: 0.075, thickness: 0.012)
        geometry.materials = [front, back, rim, rim]
        let discNode = SCNNode(geometry: geometry)
        let gloss = SCNNode(geometry: Self.discGeometry(outer: 0.598, inner: 0.165, thickness: 0.0125, faces: .front))
        gloss.geometry?.materials = [Self.glassy(strength: 0.4)]
        gloss.renderingOrder = 11
        discNode.addChildNode(gloss)

        let pivot = SCNNode()
        pivot.addChildNode(discNode)
        pivot.position = SCNVector3(0.05, 0, 0)
        pivot.opacity = 0
        return pivot
    }

    enum DiscFaces { case all, front }

    /// Anneau plat (vrai trou central) : face avant, face arrière, tranche extérieure et intérieure.
    static func discGeometry(outer r1: Float, inner r0: Float, thickness: Float, faces: DiscFaces = .all, segments n: Int = 160) -> SCNGeometry {
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uvs: [CGPoint] = []
        var elements: [SCNGeometryElement] = []
        let h = thickness / 2

        func face(z: Float, front: Bool) {
            let base = UInt32(positions.count)
            for i in 0...n {
                let a = Float(i) / Float(n) * 2 * .pi
                for r in [r0, r1] {
                    let x = cos(a) * r, y = sin(a) * r
                    positions.append(SCNVector3(x, y, z))
                    normals.append(SCNVector3(0, 0, front ? 1 : -1))
                    // Le dos est vu en miroir : on retourne l'image pour qu'elle se lise à l'endroit.
                    let u = front ? 0.5 + x / (2 * r1) : 0.5 - x / (2 * r1)
                    uvs.append(CGPoint(x: CGFloat(u), y: CGFloat(0.5 - y / (2 * r1))))
                }
            }
            var idx: [UInt32] = []
            for i in 0..<UInt32(n) {
                let a = base + i * 2, b = a + 1, c = a + 2, d = a + 3
                idx += front ? [a, b, d, a, d, c] : [a, d, b, a, c, d]
            }
            elements.append(SCNGeometryElement(indices: idx, primitiveType: .triangles))
        }

        func wall(radius r: Float, outward: Bool) {
            let base = UInt32(positions.count)
            for i in 0...n {
                let a = Float(i) / Float(n) * 2 * .pi
                let c = cos(a), s = sin(a)
                for z in [-h, h] {
                    positions.append(SCNVector3(c * r, s * r, z))
                    normals.append(outward ? SCNVector3(c, s, 0) : SCNVector3(-c, -s, 0))
                    uvs.append(CGPoint(x: CGFloat(i) / CGFloat(n), y: z > 0 ? 0 : 1))
                }
            }
            var idx: [UInt32] = []
            for i in 0..<UInt32(n) {
                let v0 = base + i * 2, v1 = v0 + 1, v2 = v0 + 2, v3 = v0 + 3
                idx += outward ? [v0, v2, v3, v0, v3, v1] : [v0, v3, v2, v0, v1, v3]
            }
            elements.append(SCNGeometryElement(indices: idx, primitiveType: .triangles))
        }

        face(z: h, front: true)
        if faces == .all {
            face(z: -h, front: false)
            wall(radius: r1, outward: true)
            wall(radius: r0, outward: false)
        }
        let sources = [SCNGeometrySource(vertices: positions),
                       SCNGeometrySource(normals: normals),
                       SCNGeometrySource(textureCoordinates: uvs)]
        return SCNGeometry(sources: sources, elements: elements)
    }

    /// Face imprimée : la pochette sur la zone d'impression, puis l'anneau miroir,
    /// l'anneau d'empilage et le moyeu en plastique transparent, comme un vrai CD.
    static func discLabel(_ cover: UIImage?) -> UIImage {
        let size: CGFloat = 1024
        let R = size / 2
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { ctx in
            let c = ctx.cgContext
            let center = CGPoint(x: R, y: R)
            func circle(_ f: CGFloat) -> CGRect {
                CGRect(x: R - R * f, y: R - R * f, width: 2 * R * f, height: 2 * R * f)
            }
            func ring(_ outer: CGFloat, _ inner: CGFloat, _ color: UIColor) {
                c.saveGState()
                let path = UIBezierPath(ovalIn: circle(outer))
                path.append(UIBezierPath(ovalIn: circle(inner)).reversing())
                c.addPath(path.cgPath)
                c.setFillColor(color.cgColor)
                c.fillPath()
                c.restoreGState()
            }

            // Bord transparent du disque.
            ring(1.0, 0.985, UIColor(white: 0.85, alpha: 0.35))

            // Zone imprimée (de 38 à 118 mm).
            c.saveGState()
            let printPath = UIBezierPath(ovalIn: circle(0.985))
            printPath.append(UIBezierPath(ovalIn: circle(0.36)).reversing())
            c.addPath(printPath.cgPath)
            c.clip()
            if let cg = cover?.cgImage {
                let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
                let scale = max(size / iw, size / ih)
                let w = iw * scale, h = ih * scale
                // UIKit dessine à l'endroit (pas besoin de retourner l'image ici).
                cover?.draw(in: CGRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h))
            } else {
                c.setFillColor(UIColor(white: 0.9, alpha: 1).cgColor)
                c.fill(CGRect(x: 0, y: 0, width: size, height: size))
            }
            // Léger assombrissement vers le centre, comme une impression sérigraphiée.
            let colors = [UIColor(white: 0, alpha: 0.22).cgColor, UIColor(white: 0, alpha: 0).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                c.drawRadialGradient(grad, startCenter: center, startRadius: R * 0.36, endCenter: center, endRadius: R * 0.55, options: [])
            }
            c.restoreGState()
            ring(0.985, 0.978, UIColor(white: 0, alpha: 0.25))

            // Anneau miroir (sans impression) puis anneau d'empilage en relief.
            ring(0.36, 0.30, UIColor(white: 0.78, alpha: 1))
            ring(0.355, 0.35, UIColor(white: 1, alpha: 0.6))
            ring(0.30, 0.285, UIColor(white: 0.55, alpha: 0.9))
            ring(0.285, 0.265, UIColor(white: 0.8, alpha: 0.75))
            // Moyeu en plastique transparent jusqu'au trou.
            ring(0.265, 0.125, UIColor(white: 0.92, alpha: 0.16))
            ring(0.135, 0.125, UIColor(white: 1, alpha: 0.35))
        }
    }

    /// Face du couvercle : transparente, avec le cadre en cristal tout autour,
    /// la séparation de la charnière et le liseré qui entoure la pochette.
    static let lidFace: UIImage = {
        let w: CGFloat = 1136, h: CGFloat = 1000
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            let c = ctx.cgContext
            // Cadre extérieur : bande de cristal blanc translucide.
            let outer = CGRect(x: 0, y: 0, width: w, height: h)
            let frame = UIBezierPath(rect: outer)
            frame.append(UIBezierPath(rect: outer.insetBy(dx: 14, dy: 14)).reversing())
            c.addPath(frame.cgPath)
            c.setFillColor(UIColor(white: 1, alpha: 0.16).cgColor)
            c.fillPath()
            c.setStrokeColor(UIColor(white: 1, alpha: 0.9).cgColor)
            c.setLineWidth(4)
            c.stroke(outer.insetBy(dx: 2, dy: 2))
            c.setStrokeColor(UIColor(white: 1, alpha: 0.45).cgColor)
            c.setLineWidth(2.5)
            c.stroke(outer.insetBy(dx: 13, dy: 13))
            // Fines stries le long des bords haut et bas.
            c.setFillColor(UIColor(white: 1, alpha: 0.22).cgColor)
            var x: CGFloat = 170
            while x < w - 20 {
                c.fill(CGRect(x: x, y: 5, width: 1.5, height: 6))
                c.fill(CGRect(x: x, y: h - 11, width: 1.5, height: 6))
                x += 7
            }
            // Séparation entre la charnière et la pochette.
            c.setStrokeColor(UIColor(white: 1, alpha: 0.7).cgColor)
            c.setLineWidth(3)
            c.strokeLineSegments(between: [CGPoint(x: 150, y: 14), CGPoint(x: 150, y: h - 14)])
            c.setStrokeColor(UIColor(white: 1, alpha: 0.35).cgColor)
            c.setLineWidth(2)
            c.strokeLineSegments(between: [CGPoint(x: 158, y: 14), CGPoint(x: 158, y: h - 14),
                                           CGPoint(x: 26, y: 14), CGPoint(x: 26, y: h - 14)])
            // Liseré autour de la pochette.
            c.setStrokeColor(UIColor(white: 1, alpha: 0.28).cgColor)
            c.setLineWidth(2)
            c.stroke(CGRect(x: 160, y: 20, width: w - 176, height: h - 40))
        }
    }()

    /// Bande de charnière : plastique bleu-gris translucide, trois pastilles rondes.
    static let hingeStrip: UIImage = {
        let w: CGFloat = 190, h: CGFloat = 1220
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            let c = ctx.cgContext
            let colors = [UIColor(red: 0.42, green: 0.48, blue: 0.62, alpha: 0.8).cgColor,
                          UIColor(red: 0.3, green: 0.35, blue: 0.47, alpha: 0.8).cgColor,
                          UIColor(red: 0.4, green: 0.46, blue: 0.6, alpha: 0.8).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
                c.drawLinearGradient(grad, start: .zero, end: CGPoint(x: w, y: 0), options: [])
            }
            // Arêtes verticales qui accrochent la lumière.
            c.setFillColor(UIColor(white: 1, alpha: 0.35).cgColor)
            c.fill(CGRect(x: 8, y: 0, width: 3, height: h))
            c.fill(CGRect(x: w - 14, y: 0, width: 3, height: h))
            c.setFillColor(UIColor(white: 0, alpha: 0.18).cgColor)
            c.fill(CGRect(x: 14, y: 0, width: 4, height: h))
            // Les trois pastilles moulées.
            for f in [0.16, 0.5, 0.84] {
                let center = CGPoint(x: w / 2, y: h * CGFloat(f))
                let r: CGFloat = 26
                let circle = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
                c.setFillColor(UIColor(white: 0, alpha: 0.12).cgColor)
                c.fillEllipse(in: circle)
                c.setStrokeColor(UIColor(white: 1, alpha: 0.4).cgColor)
                c.setLineWidth(3)
                c.strokeEllipse(in: circle)
                c.setStrokeColor(UIColor(white: 0, alpha: 0.2).cgColor)
                c.setLineWidth(2)
                c.strokeEllipse(in: circle.insetBy(dx: 4, dy: 4))
            }
        }
    }()

    /// Numéro de série gravé autour du centre (toujours le même pour un album).
    static func matrixCode(_ album: AlbumInfo) -> String {
        var hash = 0
        for scalar in album.id.unicodeScalars {
            hash = (hash &* 31 &+ Int(scalar.value)) & 0xffff
        }
        let serial: Int = hash % 9000 + 1000
        let artist: String = album.artist.uppercased()
        let title: String = album.title.uppercased()
        return "PLATINE  ·  " + artist + " — " + title + "  ·  PL-" + String(serial) + "-2  ·  01  "
    }

    /// Face gravée (le dessous d'un vrai CD) : miroir de l'anneau central, zone de données,
    /// fines pistes, et le numéro de série gravé autour du centre.
    static func discDataSide(matrix: String) -> UIImage {
        let size: CGFloat = 1024
        let R = size / 2
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { ctx in
            let c = ctx.cgContext
            func circle(_ f: CGFloat) -> CGRect {
                CGRect(x: R - R * f, y: R - R * f, width: 2 * R * f, height: 2 * R * f)
            }
            func ring(_ outer: CGFloat, _ inner: CGFloat, _ color: UIColor) {
                let path = UIBezierPath(ovalIn: circle(outer))
                path.append(UIBezierPath(ovalIn: circle(inner)).reversing())
                c.addPath(path.cgPath)
                c.setFillColor(color.cgColor)
                c.fillPath()
            }
            // Bord en plastique transparent.
            ring(1.0, 0.985, UIColor(white: 0.85, alpha: 0.4))
            // Zone gravée : argent clair (le shader ajoute reflets et arcs-en-ciel).
            ring(0.985, 0.37, UIColor(white: 0.92, alpha: 1))
            // Fin des données : la partie gravée est un peu plus sombre que le bord vierge.
            ring(0.9, 0.37, UIColor(red: 0.84, green: 0.83, blue: 0.88, alpha: 1))
            c.setLineWidth(1)
            var f: CGFloat = 0.38
            var k = 0
            while f < 0.9 {
                c.setStrokeColor(UIColor(white: k % 3 == 0 ? 0 : 1, alpha: 0.05).cgColor)
                c.strokeEllipse(in: circle(f))
                f += 0.006
                k += 1
            }
            ring(0.903, 0.897, UIColor(white: 0.6, alpha: 0.5))
            // Anneau miroir puis anneau d'empilage.
            ring(0.37, 0.30, UIColor(white: 0.97, alpha: 1))
            ring(0.30, 0.285, UIColor(white: 0.55, alpha: 0.9))
            ring(0.285, 0.265, UIColor(white: 0.82, alpha: 0.8))
            // Centre transparent jusqu'au trou.
            ring(0.265, 0.125, UIColor(white: 0.92, alpha: 0.16))
            ring(0.135, 0.125, UIColor(white: 1, alpha: 0.35))

            // Numéro de série gravé en tout petit dans l'anneau miroir.
            let font = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(white: 0.45, alpha: 0.9)]
            let radius = R * 0.325
            var angle: CGFloat = -.pi / 2
            for ch in matrix {
                let str = String(ch) as NSString
                let w = str.size(withAttributes: attrs).width
                let step = (w + 1.5) / radius
                angle += step / 2
                c.saveGState()
                c.translateBy(x: R, y: R)
                c.rotate(by: angle + .pi / 2)
                str.draw(at: CGPoint(x: -w / 2, y: -radius - 8), withAttributes: attrs)
                c.restoreGState()
                angle += step / 2
                if angle > 1.5 * .pi - 0.05 { break }
            }
        }
    }

    /// Reflet de la face gravée : un « nœud papillon » de lumière qui tourne avec le disque,
    /// bordé d'arcs-en-ciel, comme quand on penche un vrai CD sous une lampe.
    static let diffraction = """
    #pragma body
    float2 p = _surface.diffuseTexcoord - float2(0.5, 0.5);
    float r = length(p) * 2.0;
    float a = atan2(p.y, p.x);
    float3 n = normalize(_surface.normal);
    float tilt = n.x * 2.6 + n.y * 1.8;
    float ang = a + tilt;
    float zone = smoothstep(0.37, 0.39, r) * (1.0 - smoothstep(0.97, 0.985, r));
    float bow = pow(abs(cos(ang)), 10.0);
    float soft = pow(abs(cos(ang)), 2.0);
    float3 silver = float3(0.5, 0.51, 0.55) + float3(0.42, 0.42, 0.42) * bow + float3(0.12, 0.12, 0.12) * soft;
    float hue = ang / 3.14159 * 2.0 + r * 1.3 + tilt * 0.25;
    float3 rainbow = 0.5 + 0.5 * cos(6.28318 * (hue + float3(0.0, 0.33, 0.67)));
    float fan = pow(abs(sin(ang + 0.55)), 16.0) + pow(abs(sin(ang - 0.55)), 16.0);
    float3 dataColor = silver + rainbow * (0.12 + 0.5 * fan) * smoothstep(0.4, 0.62, r);
    float3 base = _output.color.rgb;
    _output.color.rgb = mix(base, saturate(dataColor * base * 1.12), zone);
    // L'anneau miroir central brille aussi selon l'angle.
    float mirror = smoothstep(0.30, 0.31, r) * (1.0 - smoothstep(0.36, 0.37, r));
    _output.color.rgb += float3(0.25, 0.25, 0.25) * mirror * bow;
    """

    /// Tranche du boîtier : titre et artiste écrits dans la longueur.
    static func spineImage(title: String, artist: String, color: UIColor) -> UIImage {
        let w: CGFloat = 96, h: CGFloat = 1400
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            let c = ctx.cgContext
            // Couleur de la pochette, assombrie pour rester élégante.
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            c.setFillColor(UIColor(red: r * 0.45, green: g * 0.45, blue: b * 0.45, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            c.setFillColor(UIColor(white: 1, alpha: 0.08).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: 3))
            c.fill(CGRect(x: 0, y: h - 3, width: w, height: 3))

            let text = NSMutableAttributedString(string: artist.uppercased(), attributes: [
                .font: UIFont.systemFont(ofSize: 40, weight: .heavy),
                .foregroundColor: UIColor.white,
                .kern: 2
            ])
            text.append(NSAttributedString(string: "   " + title, attributes: [
                .font: UIFont.systemFont(ofSize: 40, weight: .medium),
                .foregroundColor: UIColor(white: 1, alpha: 0.75)
            ]))
            let maxLength = h - 140
            var bounds = text.boundingRect(with: CGSize(width: 10_000, height: 100), options: [], context: nil)
            let shrink = min(1, maxLength / max(bounds.width, 1))
            c.saveGState()
            // Écrit de haut en bas, comme sur un vrai boîtier.
            c.translateBy(x: w / 2, y: h / 2)
            c.rotate(by: .pi / 2)
            c.scaleBy(x: shrink, y: shrink)
            bounds = text.boundingRect(with: CGSize(width: 10_000, height: 100), options: [], context: nil)
            text.draw(at: CGPoint(x: -bounds.width / 2, y: -bounds.height / 2))
            c.restoreGState()

            // Petit logo Platine en bas de la tranche.
            let mark = NSAttributedString(string: "◉", attributes: [
                .font: UIFont.systemFont(ofSize: 34, weight: .bold),
                .foregroundColor: UIColor(white: 1, alpha: 0.6)
            ])
            let mb = mark.size()
            mark.draw(at: CGPoint(x: (w - mb.width) / 2, y: h - 70))
        }
    }

    // MARK: Boîtier de jeu PS5 : plastique bleu, jaquette sous film, couvercle qui s'ouvre.

    /// La jaquette : ta photo si tu en as mis une, sinon une jaquette générée.
    func gameCover(_ album: AlbumInfo, game: String) -> UIImage {
        if let img = library.gameCoverImage(game) { return img }
        return cached("gamecover-auto|" + game + "|" + String(album.tracks.count)) {
            Self.generatedGameCover(title: game, season: GameCatalog.season(game), count: album.tracks.count)
        } ?? UIImage()
    }

    private func makeGameCase(_ album: AlbumInfo, badges: [AlbumBadge], extras: Bool, signature: String) -> AlbumNode {
        let size = Physical.size(.game)
        let W = CGFloat(size.x), H = CGFloat(size.y)
        let game = library.gameName(album.id) ?? album.title
        var parts: [SCNNode] = []

        // Plastique bleu translucide des boîtiers PS5.
        let blue = SCNMaterial()
        blue.lightingModel = .physicallyBased
        blue.diffuse.contents = UIColor(red: 0.13, green: 0.38, blue: 0.93, alpha: 0.9)
        blue.roughness.contents = 0.3
        blue.metalness.contents = 0.0
        blue.clearCoat.contents = 0.5
        blue.clearCoatRoughness.contents = 0.2
        blue.blendMode = .alpha

        let cover = gameCover(album, game: game)
        let back = cached("gameback|" + signature) {
            Self.gameBackInsert(cover: cover, title: game, season: GameCatalog.season(game),
                                tracks: album.tracks.map { ($0.title, $0.displayArtist) })
        }
        let booklet = cached("gamebook|" + signature) {
            Self.gameBooklet(title: game, tracks: album.tracks.map { ($0.title, $0.displayArtist) })
        }
        let spine = cached("gamespine|" + game) {
            Self.spineImage(title: "Bande-son originale", artist: game, color: UIColor(red: 0.3, green: 0.6, blue: 1, alpha: 1))
        }

        // Partie arrière : le plateau bleu clair où le disque est clipsé, le dos imprimé.
        let shell = SCNBox(width: W, height: H, length: 0.04, chamferRadius: 0.02)
        shell.materials = [Self.printed(Self.gameTray), blue, Self.printed(back ?? UIColor.darkGray), blue, blue, blue]
        let shellNode = SCNNode(geometry: shell)
        shellNode.position.z = -0.05
        parts.append(shellNode)
        // Rebords du plateau tout autour.
        let rims: [(CGFloat, CGFloat, Float, Float)] = [
            (W, 0.03, 0, Float(H / 2 - 0.015)), (W, 0.03, 0, Float(-H / 2 + 0.015)),
            (0.03, H, Float(W / 2 - 0.015), 0), (0.03, H, Float(-W / 2 + 0.015), 0)
        ]
        for (w, h, x, y) in rims {
            let rim = SCNBox(width: w, height: h, length: 0.026, chamferRadius: 0.006)
            rim.materials = [blue]
            let n = SCNNode(geometry: rim)
            n.position = SCNVector3(x, y, -0.018)
            parts.append(n)
        }

        // Couvercle : il tourne autour de la charnière, à gauche, comme un livre.
        let lidPivot = SCNNode()
        lidPivot.position = SCNVector3(Float(-W / 2), 0, -0.005)
        let lid = SCNBox(width: W, height: H, length: 0.075, chamferRadius: 0.025)
        lid.materials = [blue, blue, Self.printed(booklet ?? UIColor.darkGray), Self.printed(spine ?? UIColor.darkGray), blue, blue]
        let lidNode = SCNNode(geometry: lid)
        lidNode.position = SCNVector3(Float(W / 2), 0, 0.0375)
        lidPivot.addChildNode(lidNode)
        // La jaquette glissée sous le film transparent.
        let coverPlane = SCNPlane(width: W - 0.05, height: H - 0.05)
        coverPlane.materials = [Self.printed(cover)]
        let coverNode = SCNNode(geometry: coverPlane)
        coverNode.position = SCNVector3(Float(W / 2), 0, 0.0758)
        lidPivot.addChildNode(coverNode)
        // Le film plastique : uniquement des reflets.
        let film = SCNPlane(width: W - 0.03, height: H - 0.03)
        let filmMat = Self.glassy(strength: 0.6)
        if badges.contains(.platinum) { filmMat.shaderModifiers = [.fragment: Self.iridescence] }
        film.materials = [filmMat]
        let filmNode = SCNNode(geometry: film)
        filmNode.position = SCNVector3(Float(W / 2), 0, 0.0768)
        filmNode.renderingOrder = 11
        filmNode.categoryBitMask = 2
        lidPivot.addChildNode(filmNode)
        parts.append(lidPivot)

        return AlbumNode(albumID: album.id, format: .game, signature: signature, parts: parts,
                         discPivot: extras ? makeDisc(album) : nil, reels: [], lidPivot: lidPivot)
    }

    /// Jaquette générée (en attendant ta photo) : bandeau blanc, stade de nuit, pelouse et nom du jeu.
    static func generatedGameCover(title: String, season: String, count: Int) -> UIImage {
        let w: CGFloat = 1080, h: CGFloat = 1360
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            let c = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            // Ciel de stade.
            let sky = [UIColor(red: 0.03, green: 0.06, blue: 0.16, alpha: 1).cgColor,
                       UIColor(red: 0.06, green: 0.14, blue: 0.3, alpha: 1).cgColor,
                       UIColor(red: 0.02, green: 0.05, blue: 0.1, alpha: 1).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: space, colors: sky, locations: [0, 0.55, 1]) {
                c.drawLinearGradient(g, start: CGPoint(x: 0, y: 120), end: CGPoint(x: 0, y: h), options: [])
            }
            // Projecteurs.
            for (x, y) in [(180.0, 260.0), (900.0, 240.0), (540.0, 200.0)] {
                let glow = [UIColor(white: 1, alpha: 0.55).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray
                if let g = CGGradient(colorsSpace: space, colors: glow, locations: [0, 1]) {
                    c.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                                         endCenter: CGPoint(x: x, y: y), endRadius: 260, options: [])
                }
            }
            // Tribunes : rangées de petits points lumineux.
            c.setFillColor(UIColor(white: 1, alpha: 0.08).cgColor)
            var y: CGFloat = 640
            while y < 960 {
                var x: CGFloat = CGFloat(Int(y) % 14)
                while x < w {
                    c.fillEllipse(in: CGRect(x: x, y: y, width: 4, height: 4))
                    x += 14
                }
                y += 12
            }
            // Pelouse rayée avec les lignes du terrain.
            let grass = UIBezierPath()
            grass.move(to: CGPoint(x: 0, y: 980))
            grass.addLine(to: CGPoint(x: w, y: 980))
            grass.addLine(to: CGPoint(x: w, y: h))
            grass.addLine(to: CGPoint(x: 0, y: h))
            grass.close()
            c.saveGState()
            c.addPath(grass.cgPath)
            c.clip()
            for i in 0..<10 {
                c.setFillColor((i % 2 == 0 ? UIColor(red: 0.1, green: 0.5, blue: 0.2, alpha: 1)
                                           : UIColor(red: 0.13, green: 0.58, blue: 0.24, alpha: 1)).cgColor)
                c.fill(CGRect(x: CGFloat(i) * w / 10, y: 980, width: w / 10 + 1, height: h - 980))
            }
            c.setStrokeColor(UIColor(white: 1, alpha: 0.75).cgColor)
            c.setLineWidth(5)
            c.strokeLineSegments(between: [CGPoint(x: 0, y: 1060), CGPoint(x: w, y: 1060)])
            c.strokeEllipse(in: CGRect(x: w / 2 - 230, y: 1010, width: 460, height: 120))
            c.restoreGState()
            // Ballon.
            c.setFillColor(UIColor.white.cgColor)
            c.fillEllipse(in: CGRect(x: 780, y: 1150, width: 120, height: 120))
            c.setFillColor(UIColor(white: 0.1, alpha: 1).cgColor)
            c.fillEllipse(in: CGRect(x: 822, y: 1192, width: 36, height: 36))

            // Nom du jeu, en grand et penché.
            let titleFont = UIFont.systemFont(ofSize: 220, weight: .black)
            let italic = UIFont(descriptor: titleFont.fontDescriptor.withSymbolicTraits(.traitItalic) ?? titleFont.fontDescriptor, size: 220)
            let attrs: [NSAttributedString.Key: Any] = [.font: italic, .foregroundColor: UIColor.white, .kern: -6]
            let text = title.uppercased() as NSString
            var size = text.size(withAttributes: attrs)
            let shrink = min(1, (w - 120) / max(size.width, 1))
            c.saveGState()
            c.translateBy(x: w / 2, y: 430)
            c.scaleBy(x: shrink, y: shrink)
            size = text.size(withAttributes: attrs)
            c.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: UIColor(white: 0, alpha: 0.6).cgColor)
            text.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attrs)
            c.restoreGState()

            var subText = "Bande-son originale"
            if !season.isEmpty { subText += " · " + season }
            let sub = subText as NSString
            let subAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 40, weight: .bold),
                                                            .foregroundColor: UIColor(white: 1, alpha: 0.85), .kern: 3]
            let ss = sub.size(withAttributes: subAttrs)
            sub.draw(at: CGPoint(x: (w - ss.width) / 2, y: 580), withAttributes: subAttrs)
            let countText: String = String(count) + (count > 1 ? " titres" : " titre")
            let n = countText as NSString
            let ns = n.size(withAttributes: subAttrs)
            n.draw(at: CGPoint(x: (w - ns.width) / 2, y: 1290 - ns.height), withAttributes: subAttrs)

            // Bandeau blanc en haut, comme sur les jeux PS5.
            c.setFillColor(UIColor(white: 0.96, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: 120))
            c.setFillColor(UIColor(white: 0.82, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 118, width: w, height: 4))
            let band = "PLATINE · BANDE-SON" as NSString
            let bandAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 44, weight: .heavy),
                                                             .foregroundColor: UIColor(white: 0.12, alpha: 1), .kern: 4]
            band.draw(at: CGPoint(x: 48, y: 34), withAttributes: bandAttrs)
        }
    }

    /// Dos du boîtier : visuel en haut, liste des morceaux, code-barres.
    static func gameBackInsert(cover: UIImage, title: String, season: String, tracks: [(String, String)]) -> UIImage {
        let w: CGFloat = 1080, h: CGFloat = 1360
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(red: 0.04, green: 0.06, blue: 0.12, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            c.setFillColor(UIColor(white: 0.96, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: 90))
            // Bandeau visuel repris de la jaquette.
            if let cg = cover.cgImage {
                let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
                c.saveGState()
                c.clip(to: CGRect(x: 60, y: 130, width: w - 120, height: 380))
                let scale = max((w - 120) / iw, 380 / ih)
                cover.draw(in: CGRect(x: 60 + ((w - 120) - iw * scale) / 2, y: 130 + (380 - ih * scale) / 2,
                                      width: iw * scale, height: ih * scale))
                c.restoreGState()
            }
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 56, weight: .black),
                                                              .foregroundColor: UIColor.white]
            (title.uppercased() as NSString).draw(at: CGPoint(x: 60, y: 540), withAttributes: titleAttrs)
            let subAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 30, weight: .semibold),
                                                            .foregroundColor: UIColor(white: 1, alpha: 0.6)]
            var subtitle = "Bande-son originale"
            if !season.isEmpty { subtitle += " · " + season }
            (subtitle as NSString).draw(at: CGPoint(x: 60, y: 615), withAttributes: subAttrs)
            // Liste des morceaux, sur deux colonnes si besoin.
            let lineAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 26, weight: .medium),
                                                             .foregroundColor: UIColor(white: 1, alpha: 0.9)]
            let artistAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 22, weight: .regular),
                                                               .foregroundColor: UIColor(white: 1, alpha: 0.5)]
            let shown = Array(tracks.prefix(24))
            let perColumn = shown.count > 12 ? (shown.count + 1) / 2 : 12
            for (i, t) in shown.enumerated() {
                let col = CGFloat(i / perColumn), row = CGFloat(i % perColumn)
                let x = 60 + col * (w - 120) / 2, y = 690 + row * 46
                let maxW = (shown.count > 12 ? (w - 120) / 2 : w - 120) - 20
                let number: String = String(i + 1) + ". "
                let line: String = number + t.0
                (line as NSString).draw(in: CGRect(x: x, y: y, width: maxW * 0.62, height: 32), withAttributes: lineAttrs)
                (t.1 as NSString).draw(in: CGRect(x: x + maxW * 0.64, y: y + 3, width: maxW * 0.36, height: 30), withAttributes: artistAttrs)
            }
            // Pied de page : code-barres et note d'âge générique.
            c.setFillColor(UIColor.white.cgColor)
            c.fill(CGRect(x: w - 300, y: h - 170, width: 240, height: 110))
            c.setFillColor(UIColor.black.cgColor)
            var x: CGFloat = w - 288
            var k = 0
            while x < w - 72 {
                let bw: CGFloat = [2, 4, 3, 6, 2, 5][k % 6]
                c.fill(CGRect(x: x, y: h - 160, width: bw, height: 80))
                x += bw + 3
                k += 1
            }
            c.setFillColor(UIColor(red: 0.2, green: 0.6, blue: 0.25, alpha: 1).cgColor)
            c.fill(CGRect(x: 60, y: h - 170, width: 90, height: 110))
            let age = "3+" as NSString
            age.draw(at: CGPoint(x: 72, y: h - 150), withAttributes: [.font: UIFont.systemFont(ofSize: 54, weight: .black),
                                                                     .foregroundColor: UIColor.white])
        }
    }

    /// Livret, visible à l'intérieur du couvercle quand on ouvre le boîtier.
    static func gameBooklet(title: String, tracks: [(String, String)]) -> UIImage {
        let w: CGFloat = 1080, h: CGFloat = 1360
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            let c = ctx.cgContext
            // Fond du couvercle (bleu clair) et le livret posé dessus.
            c.setFillColor(UIColor(red: 0.6, green: 0.74, blue: 0.95, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let card = CGRect(x: 110, y: 120, width: w - 220, height: h - 240)
            c.setFillColor(UIColor(red: 0.05, green: 0.07, blue: 0.1, alpha: 1).cgColor)
            c.fill(card)
            let head: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 60, weight: .black),
                                                        .foregroundColor: UIColor(red: 0.45, green: 0.95, blue: 0.55, alpha: 1)]
            ("ÉCOUTE LA" as NSString).draw(at: CGPoint(x: card.minX + 60, y: card.minY + 70), withAttributes: head)
            ("BANDE-SON" as NSString).draw(at: CGPoint(x: card.minX + 60, y: card.minY + 140), withAttributes: head)
            let sub: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 34, weight: .bold),
                                                       .foregroundColor: UIColor.white]
            (title.uppercased() as NSString).draw(at: CGPoint(x: card.minX + 60, y: card.minY + 230), withAttributes: sub)
            let line: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 26, weight: .regular),
                                                        .foregroundColor: UIColor(white: 1, alpha: 0.75)]
            for (i, t) in tracks.prefix(16).enumerated() {
                let entry: String = t.0 + " — " + t.1
                (entry as NSString).draw(in: CGRect(x: card.minX + 60, y: card.minY + 320 + CGFloat(i) * 44,
                                                                  width: card.width - 120, height: 34), withAttributes: line)
            }
            // Les deux clips qui tiennent le livret.
            c.setFillColor(UIColor(red: 0.45, green: 0.6, blue: 0.9, alpha: 0.9).cgColor)
            c.fill(CGRect(x: 80, y: 200, width: 90, height: 80))
            c.fill(CGRect(x: 80, y: h - 280, width: 90, height: 80))
        }
    }

    /// Plateau intérieur bleu clair, avec l'emplacement du disque et son ergot central.
    static let gameTray: UIImage = {
        let w: CGFloat = 540, h: CGFloat = 680
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(red: 0.62, green: 0.76, blue: 0.97, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            c.setStrokeColor(UIColor(white: 1, alpha: 0.6).cgColor)
            c.setLineWidth(3)
            c.stroke(CGRect(x: 18, y: 18, width: w - 36, height: h - 36))
            let center = CGPoint(x: w / 2, y: h / 2 - 8)
            for (r, a) in [(250.0, 0.35), (244.0, 0.2), (40.0, 0.5), (26.0, 0.6)] {
                c.setStrokeColor(UIColor(red: 0.3, green: 0.45, blue: 0.75, alpha: CGFloat(a)).cgColor)
                c.setLineWidth(4)
                c.strokeEllipse(in: CGRect(x: center.x - CGFloat(r), y: center.y - CGFloat(r), width: CGFloat(r) * 2, height: CGFloat(r) * 2))
            }
        }
    }()

    /// Face imprimée du disque de jeu : visuel en haut, bandeau blanc en bas, nom du jeu.
    static func gameDiscLabel(_ cover: UIImage, title: String) -> UIImage {
        let base = discLabel(cover)
        let size = base.size
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            base.draw(at: .zero)
            let R = size.width / 2
            // Bandeau blanc sur le bas du disque (dans la zone imprimée seulement).
            c.saveGState()
            let printArea = UIBezierPath(ovalIn: CGRect(x: R - R * 0.985, y: R - R * 0.985, width: 2 * R * 0.985, height: 2 * R * 0.985))
            printArea.append(UIBezierPath(ovalIn: CGRect(x: R - R * 0.36, y: R - R * 0.36, width: 2 * R * 0.36, height: 2 * R * 0.36)).reversing())
            c.addPath(printArea.cgPath)
            c.clip()
            c.setFillColor(UIColor(white: 0.97, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: R * 1.38, width: size.width, height: size.height))
            c.restoreGState()
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 64, weight: .black),
                                                         .foregroundColor: UIColor.white]
            let text = title.uppercased() as NSString
            let ts = text.size(withAttributes: attrs)
            c.setShadow(offset: CGSize(width: 0, height: 3), blur: 10, color: UIColor(white: 0, alpha: 0.6).cgColor)
            text.draw(at: CGPoint(x: R - ts.width / 2, y: R * 0.42), withAttributes: attrs)
        }
    }

    // MARK: Cassette : coque fumée arrondie, vis, fenêtre vitrée et bobines.

    private func makeCassette(_ album: AlbumInfo, badges: [AlbumBadge], signature: String) -> AlbumNode {
        let size = Physical.size(.cassette)
        let W = CGFloat(size.x), H = CGFloat(size.y), D = CGFloat(size.z)
        var parts: [SCNNode] = []

        let front = cached("front|" + signature) {
            render(CassetteView(album: album, sideB: false, spinning: false, progress: 0, lightX: 0, badges: badges),
                   CGSize(width: 632, height: 400))
        }
        let back = cached("sideb|" + signature) {
            render(CassetteView(album: album, sideB: true, spinning: false, progress: 0, lightX: 0, badges: []),
                   CGSize(width: 632, height: 400))
        }
        let shell = SCNBox(width: W, height: H, length: D, chamferRadius: 0.035)
        let side = Self.plastic(UIColor(white: 0.11, alpha: 1), roughness: 0.55, coat: 0.15)
        shell.materials = [Self.printed(front ?? UIColor.darkGray), side, Self.printed(back ?? UIColor.darkGray), side, side, side]
        parts.append(SCNNode(geometry: shell))

        // Vernis : uniquement des reflets, posés par-dessus les deux faces.
        for face in [1.0, -1.0] {
            let gloss = SCNPlane(width: W - 0.04, height: H - 0.04)
            gloss.cornerRadius = 0.03
            let m = Self.glassy(strength: 0.35)
            if face > 0 && badges.contains(.platinum) { m.shaderModifiers = [.fragment: Self.iridescence] }
            gloss.materials = [m]
            let n = SCNNode(geometry: gloss)
            n.position.z = Float(face * Double(D / 2 + 0.001))
            if face < 0 { n.eulerAngles.y = .pi }
            n.renderingOrder = 9
            parts.append(n)
        }

        // Vis en métal, en relief sur les deux faces.
        let screwMat = Self.plastic(UIColor(white: 0.6, alpha: 1), roughness: 0.3, coat: 0)
        screwMat.metalness.contents = 1.0
        let screwSpots: [(Double, Double)] = [(0.04, 0.07), (0.96, 0.07), (0.04, 0.93), (0.96, 0.93), (0.5, 0.9)]
        for face in [1.0, -1.0] {
            for (fx, fy) in screwSpots {
                let screw = SCNCylinder(radius: 0.02, height: 0.006)
                screw.materials = [screwMat]
                let n = SCNNode(geometry: screw)
                n.eulerAngles.x = .pi / 2
                n.position = SCNVector3(Float((fx - 0.5) * Double(W)) * Float(face), Float((0.5 - fy) * Double(H)), Float(face * Double(D / 2)))
                parts.append(n)
            }
        }

        // Vitre de la fenêtre, légèrement en relief.
        let glass = SCNPlane(width: W * 0.5, height: H * 0.21)
        glass.cornerRadius = H * 0.05
        glass.materials = [Self.glassy(strength: 0.8)]
        let glassNode = SCNNode(geometry: glass)
        glassNode.position = SCNVector3(0, Float(0.055 * Double(H)), Float(D / 2) + 0.006)
        glassNode.renderingOrder = 10
        parts.append(glassNode)

        // Les deux moyeux, qui tournent pendant la lecture.
        var reels: [SCNNode] = []
        let hub = Self.plastic(Self.reelImage, roughness: 0.45, coat: 0)
        for s in [-1.0, 1.0] {
            let reel = SCNCylinder(radius: 0.044, height: 0.004)
            reel.materials = [hub, hub, hub]
            let reelNode = SCNNode(geometry: reel)
            reelNode.eulerAngles.x = .pi / 2
            let pivot = SCNNode()
            pivot.addChildNode(reelNode)
            pivot.position = SCNVector3(Float(s * 0.2535), Float(0.0494), Float(D / 2) + 0.003)
            reels.append(pivot)
        }

        return AlbumNode(albumID: album.id, format: .cassette, signature: signature, parts: parts, discPivot: nil, reels: reels)
    }

    // MARK: Outils

    private func render<V: View>(_ view: V, _ size: CGSize, scale: CGFloat = 1.6) -> UIImage? {
        let content = view
            .frame(width: size.width, height: size.height)
            .environment(library)
            .environment(settings)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// Les faces dessinées sont gardées en mémoire : rouvrir un album ne les redessine pas.
    static let textures: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 80
        return c
    }()

    private func cached(_ key: String, _ make: () -> UIImage?) -> UIImage? {
        if let img = Self.textures.object(forKey: key as NSString) { return img }
        guard let img = make() else { return nil }
        Self.textures.setObject(img, forKey: key as NSString)
        return img
    }

    /// Impression (pochette, jaquette) : couleurs fidèles, sans être éclaircies par les projecteurs.
    static func printed(_ contents: Any) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = contents
        m.multiply.contents = UIColor(white: 0.94, alpha: 1)
        return m
    }

    /// Plastique transparent : noir en mode « addition », il ne laisse voir que ses reflets.
    static func glassy(strength: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor.black
        m.roughness.contents = 0.14
        m.metalness.contents = 0.0
        m.blendMode = .add
        m.transparency = strength
        m.writesToDepthBuffer = false
        return m
    }

    /// Plastique physique, avec un vernis discret.
    static func plastic(_ contents: Any, roughness: CGFloat, coat: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = contents
        m.roughness.contents = roughness
        m.metalness.contents = 0.0
        if coat > 0 {
            m.clearCoat.contents = coat
            m.clearCoatRoughness.contents = 0.25
        }
        return m
    }

    /// Reflet arc-en-ciel discret qui change selon l'angle de vue (albums disque de platine).
    static let iridescence = """
    #pragma body
    float3 v = normalize(_surface.view);
    float3 n = normalize(_surface.normal);
    float facing = saturate(dot(v, n));
    float phase = facing * 2.2 + _surface.diffuseTexcoord.x * 1.6 + _surface.diffuseTexcoord.y * 0.8;
    float3 rainbow = 0.5 + 0.5 * cos(6.28318 * (phase + float3(0.0, 0.33, 0.67)));
    _output.color.rgb += rainbow * 0.12 * (1.1 - facing);
    """

    /// Stries de la charnière.
    static let ridges: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 512)).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(white: 0.05, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: 64, height: 512))
            c.setFillColor(UIColor(white: 0.16, alpha: 1).cgColor)
            var y: CGFloat = 8
            while y < 504 {
                c.fill(CGRect(x: 14, y: y, width: 36, height: 2))
                y += 7
            }
        }
    }()

    static let reelImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(white: 0.93, alpha: 1).cgColor)
            c.fillEllipse(in: CGRect(x: 0, y: 0, width: 128, height: 128))
            c.setFillColor(UIColor.black.cgColor)
            c.fillEllipse(in: CGRect(x: 35, y: 35, width: 58, height: 58))
            c.setFillColor(UIColor(white: 0.93, alpha: 1).cgColor)
            for k in 0..<6 {
                let a = Double(k) / 6 * 2 * .pi
                let p = CGPoint(x: 64 + cos(a) * 29, y: 64 + sin(a) * 29)
                c.fill(CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
            }
        }
    }()

    /// Ombre douce posée au sol sous un objet (bien plus légère qu'une vraie ombre calculée).
    static let contactShadow: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 256, height: 128)).image { ctx in
            let colors = [UIColor(white: 0, alpha: 0.7).cgColor, UIColor(white: 0, alpha: 0).cgColor] as CFArray
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.cgContext.scaleBy(x: 2, y: 1)
            ctx.cgContext.drawRadialGradient(grad, startCenter: CGPoint(x: 64, y: 64), startRadius: 0,
                                             endCenter: CGPoint(x: 64, y: 64), endRadius: 64, options: [])
        }
    }()
}

/// Recto d'une pochette pour la 3D : l'image, ses badges, et le voile irisé des disques de platine.
struct CoverFace: View {
    let album: AlbumInfo
    let badges: [AlbumBadge]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                ArtworkView(track: album.first, animated: false, cornerRadius: 0)
                if badges.contains(.platinum) { HoloSheen(light: -0.2) }
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(badges) { HoloBadge(badge: $0, light: -0.3, scale: geo.size.width / 220) }
                }
                .padding(geo.size.width * 0.035)
            }
        }
    }
}

// MARK: - Studio : lumières douces, reflets discrets, sol sombre

enum Studio {
    static let environment: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 512, height: 256)).image { ctx in
            let c = ctx.cgContext
            let colors = [UIColor(white: 0.14, alpha: 1).cgColor, UIColor(white: 0.02, alpha: 1).cgColor] as CFArray
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            c.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: 256), options: [])
            c.setFillColor(UIColor(white: 1, alpha: 0.55).cgColor)
            c.fill(CGRect(x: 60, y: 60, width: 80, height: 55))
            c.fill(CGRect(x: 320, y: 45, width: 55, height: 80))
        }
    }()

    static func addLights(to scene: SCNScene, withFloor: Bool) {
        scene.lightingEnvironment.contents = environment
        scene.lightingEnvironment.intensity = 0.75

        let key = SCNLight()
        key.type = .directional
        key.intensity = 520
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.7, 0.5, 0)
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 220
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.eulerAngles = SCNVector3(-0.2, -0.9, 0)
        scene.rootNode.addChildNode(fillNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 160
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        if withFloor {
            // Projecteur coloré par la pochette, et sol sombre au reflet très discret.
            let spot = SCNLight()
            spot.type = .spot
            spot.intensity = 450
            spot.spotInnerAngle = 20
            spot.spotOuterAngle = 65
            let spotNode = SCNNode()
            spotNode.light = spot
            spotNode.name = "spot"
            spotNode.position = SCNVector3(0, 3.5, 2.0)
            spotNode.look(at: SCNVector3(0, 0, 0))
            scene.rootNode.addChildNode(spotNode)

            let floor = SCNFloor()
            floor.reflectivity = 0.1
            floor.reflectionFalloffEnd = 0.9
            floor.reflectionResolutionScaleFactor = 0.3
            floor.reflectionCategoryBitMask = 1
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = UIColor(white: 0.025, alpha: 1)
            m.roughness.contents = 0.8
            floor.materials = [m]
            scene.rootNode.addChildNode(SCNNode(geometry: floor))

            let bg = UIColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1)
            scene.background.contents = bg
            scene.fogColor = bg
            scene.fogStartDistance = 8
            scene.fogEndDistance = 15
        }
    }
}

extension SCNView {
    func configureForShelf() {
        backgroundColor = .clear
        isOpaque = false
        antialiasingMode = .multisampling2X
        preferredFramesPerSecond = 120
        rendersContinuously = true
        isPlaying = true
        isJitteringEnabled = false
    }
}

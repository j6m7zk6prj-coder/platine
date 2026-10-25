import SwiftUI
import SceneKit
import UIKit

// MARK: - Dimensions réelles (en unités de scène)

enum Physical {
    /// Boîtier CD : 142 × 125 × 10 mm. Cassette : 100 × 63 × 12 mm (agrandie à la largeur du CD).
    /// Boîtier de jeu (format Blu-ray des PS3, PS4 et PS5) : 135 × 171,5 × 14 mm.
    static func size(_ format: AlbumFormat) -> SCNVector3 {
        switch format {
        case .cd: return SCNVector3(1.42, 1.25, 0.1)
        case .cassette: return SCNVector3(1.42, 0.899, 0.17)
        case .game: return SCNVector3(1.35, 1.555, 0.14)
        }
    }

    /// Jaquette des jeux PS3, PS4 et PS5 : face et dos de 128 × 148 mm, tranche de 14 mm
    /// (jaquette complète : 270 × 148 mm). Le boîtier fait 135 × 155,5 × 14 mm.
    static let insert = CGSize(width: 1.28, height: 1.48)
    static let insertSpine: CGFloat = 0.14
    /// Jaquette complète (dos + tranche + face), largeur ÷ hauteur.
    static var wrapAspect: CGFloat { (insert.width * 2 + insertSpine) / insert.height }

    /// Profondeur du disque rangé dans le boîtier de jeu (posé sur le plateau).
    static let gameDiscZ: Float = -0.023
}

// MARK: - Un album en 3D

/// Face avant d'un objet, retournée pour son reflet (unités du modèle, avant mise à l'échelle).
struct ReflectionFace {
    let image: UIImage
    let x: Float
    let width: CGFloat
    let height: CGFloat
    let z: Float
}

final class AlbumNode {
    let albumID: String
    let format: AlbumFormat
    let signature: String
    /// Placé par la mise en page (carrousel ou vue en main).
    let root = SCNNode()
    /// Contenu mis à l'échelle : le boîtier de jeu, plus grand, est un peu réduit pour tenir dans le cadre.
    let content = SCNNode()
    /// L'objet lui-même (boîtier ou cassette), qui peut glisser quand le CD sort.
    let body = SCNNode()
    private(set) var discPivot: SCNNode?
    let reels: [SCNNode]
    /// Couvercle du boîtier de jeu, qui s'ouvre comme un livre.
    let lidPivot: SCNNode?
    /// Tranche imprimée et son film : cachées boîtier ouvert à plat.
    var spineNodes: [SCNNode] = []
    private(set) var spinning = false
    private(set) var discOut = false
    /// Image déjà retournée et fondue, pour le reflet sur le sol de la Collection.
    var reflection: ReflectionFace?

    var size: SCNVector3 { Physical.size(format) }
    /// Échelle d'affichage (le boîtier de jeu est réduit pour avoir la même présence qu'un CD).
    var fit: Float { format == .game ? 0.78 : 1 }
    /// Taille telle qu'on la voit à l'écran.
    var shownSize: SCNVector3 { SCNVector3(size.x * fit, size.y * fit, size.z * fit) }

    init(albumID: String, format: AlbumFormat, signature: String, parts: [SCNNode], discPivot: SCNNode?, reels: [SCNNode],
         lidPivot: SCNNode? = nil) {
        self.albumID = albumID
        self.format = format
        self.signature = signature
        self.discPivot = discPivot
        self.reels = reels
        self.lidPivot = lidPivot
        root.addChildNode(content)
        content.scale = SCNVector3(fit, fit, fit)
        content.addChildNode(body)
        for p in parts {
            body.addChildNode(p)
            // Les pièces transparentes ne sont pas recalculées dans le reflet du sol (plus fluide).
            if p.renderingOrder >= 9 { p.categoryBitMask = 2 }
        }
        if let discPivot {
            discPivot.position = restDisc
            content.addChildNode(discPivot)
        }
        for r in reels { body.addChildNode(r) }
    }

    private var restDisc: SCNVector3 {
        format == .game ? SCNVector3(0, 0.02, Physical.gameDiscZ) : SCNVector3(0.05, 0, 0)
    }
    private var outDisc: SCNVector3 {
        // Boîtier de jeu : le disque reste dans son plateau, juste soulevé sur son ergot.
        format == .game ? SCNVector3(0, 0.02, Physical.gameDiscZ + 0.006) : SCNVector3(0.05, 0.72, 0.02)
    }
    private var outBody: SCNVector3 { SCNVector3(0, -0.32, 0) }

    /// Le disque n'est fabriqué qu'au besoin (ouverture plus rapide).
    var hasDisc: Bool { discPivot != nil }

    func attachDisc(_ pivot: SCNNode) {
        guard discPivot == nil else { return }
        discPivot = pivot
        pivot.position = restDisc
        content.addChildNode(pivot)
        if spinning {
            pivot.runAction(.repeatForever(.rotateBy(x: 0, y: 0, z: -2 * .pi, duration: 1.8)), forKey: "spin")
        }
    }

    /// Remet l'objet au repos sans animation.
    func settle() {
        discOut = false
        lidPivot?.eulerAngles = SCNVector3(0, 0, 0)
        for n in spineNodes { n.opacity = 1 }
        content.scale = SCNVector3(fit, fit, fit)
        content.position = SCNVector3(0, 0, 0)
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
                // Le disque ralentit puis s'arrête, au lieu de se figer net.
                node.removeAction(forKey: "spin")
                let coast = SCNAction.rotateBy(x: 0, y: 0, z: -1.1, duration: 0.7)
                coast.timingMode = .easeOut
                node.runAction(coast, forKey: "spin")
            }
        }
    }

    /// Le CD sort par le haut du boîtier, comme quand on le retire à la main.
    func setDiscOut(_ out: Bool, animated: Bool = true) {
        guard let discPivot, out != discOut else { return }
        discOut = out
        if let lidPivot {
            // Boîtier de jeu : il s'ouvre à plat comme un livre ; on voit le livret à gauche,
            // le disque dans son plateau à droite. Le tout recule un peu pour tenir à l'écran.
            let openScale: Float = 0.6
            let halfWidth = Physical.size(.game).x / 2
            if out { discPivot.opacity = 1 }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.75 : 0
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.8, 0.25, 1)
            lidPivot.eulerAngles = out ? SCNVector3(0, -Float.pi, 0) : SCNVector3(0, 0, 0)
            for n in spineNodes { n.opacity = out ? 0 : 1 }
            content.scale = out ? SCNVector3(openScale, openScale, openScale) : SCNVector3(fit, fit, fit)
            content.position = out ? SCNVector3(halfWidth * openScale, 0, 0) : SCNVector3(0, 0, 0)
            discPivot.position = out ? outDisc : restDisc
            SCNTransaction.completionBlock = { [weak self] in
                if let self, !self.discOut { discPivot.opacity = 0 } else { discPivot.opacity = 1 }
            }
            SCNTransaction.commit()
            return
        }
        // Le disque glisse vraiment dans le boîtier (il reste visible tout le long, puis est rangé derrière la pochette).
        discPivot.removeAction(forKey: "fade")
        if out { discPivot.opacity = 1 }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? (out ? 0.7 : 0.55) : 0
        SCNTransaction.animationTimingFunction = out
            ? CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1)
            : CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1)
        discPivot.position = out ? SCNVector3(0.05, 0.72, 0.02) : SCNVector3(0.05, 0, 0)
        body.position = out ? SCNVector3(0, -0.32, 0) : SCNVector3(0, 0, 0)
        SCNTransaction.completionBlock = { [weak self] in
            if let self, !self.discOut { discPivot.opacity = 0 }
        }
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
        var art = library.artworkURL(album.cover)?.lastPathComponent ?? "-"
        if let game = library.gameName(album.id) {
            // Bande-son : la jaquette choisie et la liste des morceaux (dos du boîtier).
            let coverName: String = library.gameCoverName(game) ?? "auto"
            let lastID: String = album.tracks.last?.id.uuidString ?? ""
            let count: String = String(album.tracks.count)
            let console: String = library.platform(of: game).rawValue
            let backName: String = library.extraImageName("back", game) ?? "-"
            let spineName: String = library.extraImageName("spine", game) ?? "-"
            art = coverName + "#" + count + "#" + lastID + "#" + console + "#" + backName + "#" + spineName
        }
        let earned: String = badges.map(\.rawValue).joined(separator: ",")
        let mine: String = library.stickerKeys(for: album.id).joined(separator: ",")
        let placed: String = library.placementSignature(album.id)
        let discName: String = library.extraImageName("disc", album.id) ?? "-"
        let frontName: String = library.extraImageName("front", album.id) ?? "-"
        let badgeList: String = earned + ";" + mine + ";" + placed + ";" + discName + ";" + frontName
        let parts: [String] = [album.id, format.rawValue, art, badgeList, album.title, album.artist]
        return parts.joined(separator: "|")
    }

    func make(_ album: AlbumInfo, format: AlbumFormat, badges: [AlbumBadge], extras: Bool) -> AlbumNode {
        let sig = signature(album, format, badges)
        switch format {
        case .cd: return makeCD(album, badges: badges, extras: extras, signature: sig)
        case .cassette: return makeCassette(album, badges: badges, signature: sig)
        case .game: return makeGameCase(album, badges: badges, extras: extras, signature: sig)
        }
    }

    /// Génère une texture de plastique moulé avec des micro-bulles d'air et du grain réaliste.
    static func generatedTrayPlasticTexture() -> UIImage {
        let size = CGSize(width: 512, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            
            // Fond plastique noir fumé / gris très sombre
            c.setFillColor(UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1).cgColor)
            c.fill(CGRect(origin: .zero, size: size))
            
            // Ajout d'un grain fin (bruit de surface)
            for _ in 0..<8000 {
                let x = CGFloat.random(in: 0...size.width)
                let y = CGFloat.random(in: 0...size.height)
                let radius = CGFloat.random(in: 0.5...1.2)
                let alpha = CGFloat.random(in: 0.02...0.08)
                c.setFillColor(UIColor(white: CGFloat.random(in: 0...1), alpha: alpha).cgColor)
                c.fillEllipse(in: CGRect(x: x, y: y, width: radius, height: radius))
            }
            
            // Génération des bulles et points d'injection du plastique brut
            for _ in 0..<45 {
                let x = CGFloat.random(in: 20...(size.width - 20))
                let y = CGFloat.random(in: 20...(size.height - 20))
                let r = CGFloat.random(in: 2.0...7.5)
                
                c.saveGState()
                c.setShadow(offset: CGSize(width: 0.5, height: 1), blur: 1.5, color: UIColor.black.withAlphaComponent(0.7).cgColor)
                
                c.setFillColor(UIColor(red: 0.25, green: 0.27, blue: 0.32, alpha: 0.35).cgColor)
                c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                
                c.setStrokeColor(UIColor(white: 0.4, alpha: 0.25).cgColor)
                c.setLineWidth(0.8)
                c.strokeEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                c.restoreGState()
            }
            
            // Effet de traces de moulage / flux de plastique
            c.setStrokeColor(UIColor(white: 0.15, alpha: 0.15).cgColor)
            c.setLineWidth(3.0)
            for i in stride(from: 0.0, through: Double(size.height), by: 40.0) {
                c.beginPath()
                c.move(to: CGPoint(x: 0, y: CGFloat(i)))
                c.addQuadCurve(to: CGPoint(x: size.width, y: CGFloat(i) + CGFloat.random(in: -20...20)), 
                               control: CGPoint(x: size.width / 2, y: CGFloat(i) + CGFloat.random(in: -30...30)))
                c.strokePath()
            }
        }
    }

    // MARK: Boîtier CD : plateau fumé avec aspérités et bulles, couvercle cristal.

    private func makeCD(_ album: AlbumInfo, badges: [AlbumBadge], extras: Bool, signature: String) -> AlbumNode {
        let size = Physical.size(.cd)
        let W = CGFloat(size.x), H = CGFloat(size.y), D = CGFloat(size.z)
        var parts: [SCNNode] = []

        // Plateau : noir fumé texturé avec bulles et grain réaliste
        let backImage = cached("back|" + signature) {
            render(CDBackInsert(album: album, lightX: 0), CGSize(width: 568, height: 500), scale: 2.2)
        }
        let trayTexture = cached("cd_tray_textured_plastic") {
            Self.generatedTrayPlasticTexture()
        }
        let spine = cached("spine|" + signature) {
            Self.spineImage(title: album.title, artist: album.artist, color: UIColor(library.palette(for: album.cover)[0]))
        }
        let tray = SCNBox(width: W - 0.012, height: H - 0.008, length: D - 0.014, chamferRadius: 0.012)
        
        let texturedPlastic = SCNMaterial()
        texturedPlastic.lightingModel = .physicallyBased
        texturedPlastic.diffuse.contents = trayTexture
        texturedPlastic.roughness.contents = 0.42
        texturedPlastic.metalness.contents = 0.05
        texturedPlastic.clearCoat.contents = 0.35
        texturedPlastic.clearCoatRoughness.contents = 0.2
        
        let spineMat = Self.printed(spine ?? UIColor.darkGray)
        tray.materials = [texturedPlastic, spineMat, Self.printed(backImage ?? UIColor.darkGray), spineMat, texturedPlastic, texturedPlastic]
        let trayNode = SCNNode(geometry: tray)
        trayNode.position.z = -0.007
        parts.append(trayNode)

        // Pochette : un carré de 120 mm glissé sous le couvercle, décalé vers la droite.
        let cover = SCNPlane(width: 1.2, height: 1.2)
        let coverImage = cached("cover|" + signature) {
            render(CoverFace(album: album, badges: badges), CGSize(width: 600, height: 600), scale: 2.2)
        }
        cover.materials = [Self.printed(coverImage ?? UIColor.darkGray)]
        let coverNode = SCNNode(geometry: cover)
        coverNode.position = SCNVector3(Float(W / 2 - 0.62), 0, Float(D / 2 - 0.0135))
        parts.append(coverNode)

        // Charnière : bande en plastique bleuté translucide avec pastilles
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

        // Couvercle en cristal
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

        // Reflets du cristal
        let gloss = SCNPlane(width: W - 0.01, height: H - 0.01)
        let glossMat = Self.glassy(strength: 0.6)
        if badges.contains(.platinum) { glossMat.shaderModifiers = [.fragment: Self.iridescence] }
        gloss.materials = [glossMat]
        let glossNode = SCNNode(geometry: gloss)
        glossNode.position.z = Float(D / 2) + 0.0008
        glossNode.renderingOrder = 11
        parts.append(glossNode)

        for y in [-1.0, 1.0] {
            let lip = SCNBox(width: W - 0.2, height: 0.012, length: D - 0.01, chamferRadius: 0.004)
            lip.materials = [lidEdge]
            let lipNode = SCNNode(geometry: lip)
            lipNode.position = SCNVector3(0.08, Float(y * Double(H / 2 - 0.006)), 0)
            lipNode.renderingOrder = 10
            parts.append(lipNode)
        }
        for y in [-1.0, 1.0] {
            let knuckle = SCNCylinder(radius: 0.028, height: 0.1)
            knuckle.materials = [lidEdge]
            let k = SCNNode(geometry: knuckle)
            k.position = SCNVector3(Float(-W / 2 + 0.018), Float(y * Double(H / 2 - 0.12)), Float(D / 2 - 0.02))
            k.renderingOrder = 10
            parts.append(k)
        }

        let cdNode = AlbumNode(albumID: album.id, format: .cd, signature: signature, parts: parts,
                               discPivot: extras ? makeDisc(album) : nil, reels: [])
        if !extras, let coverImage {
            let key: String = "reflect|" + signature
            if let img = cached(key, { Self.reflectionImage(coverImage, frame: nil, inset: 0) }) {
                cdNode.reflection = ReflectionFace(image: img, x: Float(W / 2 - 0.62), width: 1.2, height: 1.2, z: Float(D / 2))
            }
        }
        return cdNode
    }

    func makeDisc(_ album: AlbumInfo) -> SCNNode {
        let label: UIImage?
        if let custom = library.extraImage("disc", album.id) {
            let name: String = library.extraImageName("disc", album.id) ?? "-"
            label = cached("customdisc|" + name) { Self.discLabel(custom) }
        } else if let game = library.gameName(album.id) {
            let coverName: String = library.gameCoverName(game) ?? "auto"
            let platform = library.platform(of: game)
            let key: String = "gamedisc|" + game + "|" + coverName + "|" + platform.rawValue
            label = cached(key) {
                Self.gameDiscLabel(self.gameCover(album, game: game), title: game, band: platform.bandFill)
            }
        } else {
            label = cached("disclabel|" + album.id + "|" + (library.artworkURL(album.cover)?.lastPathComponent ?? "-")) {
                Self.discLabel(library.image(for: album.cover))
            }
        }
        let front = SCNMaterial()
        front.lightingModel = .constant
        front.diffuse.contents = label
        front.multiply.contents = UIColor(white: 0.95, alpha: 1)
        front.blendMode = .alpha
        front.writesToDepthBuffer = true

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

            ring(1.0, 0.985, UIColor(white: 0.85, alpha: 0.35))

            c.saveGState()
            let printPath = UIBezierPath(ovalIn: circle(0.985))
            printPath.append(UIBezierPath(ovalIn: circle(0.36)).reversing())
            c.addPath(printPath.cgPath)
            c.clip()
            if let cg = cover?.cgImage {
                let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
                let scale = max(size / iw, size / ih)
                let w = iw * scale, h = ih * scale
                cover?.draw(in: CGRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h))
            } else {
                c.setFillColor(UIColor(white: 0.9, alpha: 1).cgColor)
                c.fill(CGRect(x: 0, y: 0, width: size, height: size))
            }
            let colors = [UIColor(white: 0, alpha: 0.22).cgColor, UIColor(white: 0, alpha: 0).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                c.drawRadialGradient(grad, startCenter: center, startRadius: R * 0.36, endCenter: center, endRadius: R * 0.55, options: [])
            }
            c.restoreGState()
            ring(0.985, 0.978, UIColor(white: 0, alpha: 0.25))

            ring(0.36, 0.30, UIColor(white: 0.78, alpha: 1))
            ring(0.355, 0.35, UIColor(white: 1, alpha: 0.6))
            ring(0.30, 0.285, UIColor(white: 0.55, alpha: 0.9))
            ring(0.285, 0.265, UIColor(white: 0.8, alpha: 0.75))
            ring(0.265, 0.125, UIColor(white: 0.92, alpha: 0.16))
            ring(0.135, 0.125, UIColor(white: 1, alpha: 0.35))
        }
    }

    static let lidFace: UIImage = {
        let w: CGFloat = 1136, h: CGFloat = 1000
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            let c = ctx.cgContext
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
            c.setFillColor(UIColor(white: 1, alpha: 0.22).cgColor)
            var x: CGFloat = 170
            while x < w - 20 {
                c.fill(CGRect(x: x, y: 5, width: 1.5, height: 6))
                c.fill(CGRect(x: x, y: h - 11, width: 1.5, height: 6))
                x += 7
            }
            c.setStrokeColor(UIColor(white: 1, alpha: 0.7).cgColor)
            c.setLineWidth(3)
            c.strokeLineSegments(between: [CGPoint(x: 150, y: 14), CGPoint(x: 150, y: h - 14)])
            c.setStrokeColor(UIColor(white: 1, alpha: 0.35).cgColor)
            c.setLineWidth(2)
            c.strokeLineSegments(between: [CGPoint(x: 158, y: 14), CGPoint(x: 158, y: h - 14),
                                           CGPoint(x: 26, y: 14), CGPoint(x: 26, y: h - 14)])
            c.setStrokeColor(UIColor(white: 1, alpha: 0.28).cgColor)
            c.setLineWidth(2)
            c.stroke(CGRect(x: 160, y: 20, width: w - 176, height: h - 40))
        }
    }()

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
            c.setFillColor(UIColor(white: 1, alpha: 0.35).cgColor)
            c.fill(CGRect(x: 8, y: 0, width: 3, height: h))
            c.fill(CGRect(x: w - 14, y: 0, width: 3, height: h))
            c.setFillColor(UIColor(white: 0, alpha: 0.18).cgColor)
            c.fill(CGRect(x: 14, y: 0, width: 4, height: h))
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

    private func stickerLayer(_ album: AlbumInfo, badges: [AlbumBadge], signature: String, onlyCustom: Bool = false) -> SCNNode? {
        let custom = library.customStickers(for: album.id)
        let shown = onlyCustom ? [] : badges
        guard !custom.isEmpty || !shown.isEmpty else { return nil }
        let key: String = "stickers|" + signature
        guard let image = cached(key, {
            renderTransparent(
                StickerStack(album: album, badges: shown, scale: 2.6)
                    .padding(26)
                    .frame(width: 540, height: 680, alignment: .topTrailing),
                CGSize(width: 540, height: 680))
        }) else { return nil }
        let plane = SCNPlane(width: 1.3, height: 1.3 * 680 / 540)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = image
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.renderingOrder = 10
        return node
    }

    private func placedStickerLayer(_ album: AlbumInfo, badges: [AlbumBadge], signature: String,
                                    width: CGFloat, height: CGFloat) -> SCNNode? {
        guard !library.stickerOrder(for: album, badges: badges).isEmpty else { return nil }
        let pixelW: CGFloat = 540
        let pixelH: CGFloat = 540 * height / width
        let key: String = "placed|" + signature
        guard let image = cached(key, {
            renderTransparent(PlacedStickers(album: album, badges: badges, size: CGSize(width: pixelW, height: pixelH)),
                              CGSize(width: pixelW, height: pixelH))
        }) else { return nil }
        let plane = SCNPlane(width: width, height: height)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = image
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.renderingOrder = 10
        return node
    }

    private func renderTransparent<V: View>(_ view: V, _ size: CGSize) -> UIImage? {
        let content = view
            .frame(width: size.width, height: size.height)
            .environment(library)
            .environment(settings)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.isOpaque = false
        return renderer.uiImage
    }

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
            ring(1.0, 0.985, UIColor(white: 0.85, alpha: 0.4))
            ring(0.985, 0.37, UIColor(white: 0.92, alpha: 1))
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
            ring(0.37, 0.30, UIColor(white: 0.97, alpha: 1))
            ring(0.30, 0.285, UIColor(white: 0.55, alpha: 0.9))
            ring(0.285, 0.265, UIColor(white: 0.82, alpha: 0.8))
            ring(0.265, 0.125, UIColor(white: 0.92, alpha: 0.16))
            ring(0.135, 0.125, UIColor(white: 1, alpha: 0.35))

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
    float mirror = smoothstep(0.30, 0.31, r) * (1.0 - smoothstep(0.36, 0.37, r));
    _output.color.rgb += float3(0.25, 0.25, 0.25) * mirror * bow;
    """

    static func spineImage(title: String, artist: String, color: UIColor) -> UIImage {
        let w: CGFloat = 96, h: CGFloat = 1400
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            let c = ctx.cgContext
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
            c.translateBy(x: w / 2, y: h / 2)
            c.rotate(by: .pi / 2)
            c.scaleBy(x: shrink, y: shrink)
            bounds = text.boundingRect(with: CGSize(width: 10_000, height: 100), options: [], context: nil)
            text.draw(at: CGPoint(x: -bounds.width / 2, y: -bounds.height / 2))
            c.restoreGState()

            let mark = NSAttributedString(string: "◉", attributes: [
                .font: UIFont.systemFont(ofSize: 34, weight: .bold),
                .foregroundColor: UIColor(white: 1, alpha: 0.6)
            ])
            let mb = mark.size()
            mark.draw(at: CGPoint(x: (w - mb.width) / 2, y: h - 70))
        }
    }

    // MARK: Boîtier de jeu PS5

    func gameCover(_ album: AlbumInfo, game: String) -> UIImage {
        if let img = library.gameCoverImage(game) { return img }
        let platform = library.platform(of: game)
        let count: String = String(album.tracks.count)
        let key: String = "gamecover-auto|" + game + "|" + count + "|" + platform.rawValue
        return cached(key) {
            Self.generatedGameCover(title: game, season: GameCatalog.season(game), count: album.tracks.count, platform: platform)
        } ?? UIImage()
    }

    private func makeGameCase(_ album: AlbumInfo, badges: [AlbumBadge], extras: Bool, signature: String) -> AlbumNode {
        let size = Physical.size(.game)
        let W = CGFloat(size.x), H = CGFloat(size.y)
        let game = library.gameName(album.id) ?? album.title
        var parts: [SCNNode] = []
        let corner: CGFloat = 0.035
        let insert = Physical.insert
        let platform = library.platform(of: game)

        let plastic = SCNMaterial()
        plastic.lightingModel = .physicallyBased
        plastic.diffuse.contents = platform.plastic
        plastic.roughness.contents = 0.26
        plastic.metalness.contents = 0.0
        plastic.clearCoat.contents = 0.7
        plastic.clearCoatRoughness.contents = 0.12
        plastic.blendMode = .alpha

        let cover = gameCover(album, game: game)
        let back: UIImage? = library.extraImage("back", game) ?? cached("gameback|" + signature) {
            Self.gameBackInsert(cover: cover, title: game, season: GameCatalog.season(game),
                                tracks: album.tracks.map { ($0.title, $0.displayArtist) })
        }
        let booklet = cached("gamebook|" + signature) {
            Self.gameBooklet(title: game, tracks: album.tracks.map { ($0.title, $0.displayArtist) }, platform: platform)
        }
        let spineKey: String = "gamespine4|" + game + "|" + platform.rawValue
        let spine: UIImage? = library.extraImage("spine", game) ?? cached(spineKey) { Self.gameSpine(title: game, platform: platform) }
        let trayImage = cached("gametray|" + platform.rawValue) { Self.gameTray(platform) }

        let backPlate = Self.roundedSlab(width: W, height: H, corner: corner, depth: 0.04, chamfer: 0.007, mode: .back)
        backPlate.materials = [plastic]
        let backNode = SCNNode(geometry: backPlate)
        backNode.position.z = -0.051
        parts.append(backNode)
        let frame = Self.roundedFrame(width: W, height: H, corner: corner, wall: 0.035, depth: 0.0275, chamfer: 0)
        frame.materials = [plastic]
        let frameNode = SCNNode(geometry: frame)
        frameNode.position.z = -0.01775
        parts.append(frameNode)
        let seam = Self.roundedFrame(width: W + 0.002, height: H + 0.002, corner: corner, wall: 0.004, depth: 0.0016, chamfer: 0)
        let seamMat = SCNMaterial()
        seamMat.lightingModel = .constant
        seamMat.diffuse.contents = platform.plasticDark
        seam.materials = [seamMat]
        let seamNode = SCNNode(geometry: seam)
        seamNode.position.z = -0.004
        parts.append(seamNode)
        let tray = SCNPlane(width: W - 0.07, height: H - 0.07)
        tray.cornerRadius = corner - 0.03
        tray.materials = [Self.printed(trayImage ?? UIColor.lightGray)]
        let trayNode = SCNNode(geometry: tray)
        trayNode.position.z = -0.0305
        parts.append(trayNode)
        let hinge = SCNCylinder(radius: 0.011, height: H - 0.16)
        hinge.materials = [plastic]
        let hingeNode = SCNNode(geometry: hinge)
        hingeNode.position = SCNVector3(Float(-W / 2) + 0.012, 0, -0.004)
        parts.append(hingeNode)
        let backPrint = SCNPlane(width: insert.width, height: insert.height)
        backPrint.cornerRadius = 0.02
        backPrint.materials = [Self.printed(back ?? UIColor.darkGray)]
        let backPrintNode = SCNNode(geometry: backPrint)
        backPrintNode.eulerAngles.y = .pi
        backPrintNode.position.z = -0.0715
        parts.append(backPrintNode)
        parts.append(Self.filmNode(width: W - 0.03, height: H - 0.03, z: -0.0722, flipped: true, platinum: false))

        let slotMat = SCNMaterial()
        slotMat.lightingModel = .physicallyBased
        slotMat.diffuse.contents = platform.plasticDark
        slotMat.roughness.contents = 0.25
        let slot = SCNPlane(width: 0.05, height: 0.42)
        slot.cornerRadius = 0.025
        slot.materials = [slotMat]
        let slotNode = SCNNode(geometry: slot)
        slotNode.eulerAngles.y = .pi / 2
        slotNode.position = SCNVector3(Float(W / 2) + 0.0012, 0, -0.005)
        parts.append(slotNode)
        for y in [-0.55, 0.55] {
            let tab = SCNBox(width: 0.006, height: 0.12, length: 0.03, chamferRadius: 0.002)
            tab.materials = [slotMat]
            let t = SCNNode(geometry: tab)
            t.position = SCNVector3(Float(W / 2) + 0.002, Float(y), -0.005)
            parts.append(t)
        }
        let spineHeight = insert.height
        let spinePlane = SCNPlane(width: Physical.insertSpine - 0.004, height: spineHeight)
        spinePlane.materials = [Self.printed(spine ?? UIColor.white)]
        let spineNode = SCNNode(geometry: spinePlane)
        spineNode.eulerAngles.y = -.pi / 2
        spineNode.position = SCNVector3(Float(-W / 2) - 0.0015, 0, -0.0015)
        parts.append(spineNode)
        let spineFilm = SCNPlane(width: Physical.insertSpine, height: spineHeight + 0.01)
        spineFilm.materials = [Self.glassy(strength: 0.55)]
        let spineFilmNode = SCNNode(geometry: spineFilm)
        spineFilmNode.eulerAngles.y = -.pi / 2
        spineFilmNode.position = SCNVector3(Float(-W / 2) - 0.0025, 0, -0.0015)
        spineFilmNode.renderingOrder = 11
        parts.append(spineFilmNode)

        let lidPivot = SCNNode()
        lidPivot.position = SCNVector3(Float(-W / 2), 0, -0.004)
        let lid = Self.roundedSlab(width: W, height: H, corner: corner, depth: 0.074, chamfer: 0.007, mode: .front)
        lid.materials = [plastic]
        let lidNode = SCNNode(geometry: lid)
        lidNode.position = SCNVector3(Float(W / 2), 0, 0.037)
        lidPivot.addChildNode(lidNode)
        let lip = Self.roundedFrame(width: W - 0.012, height: H - 0.012, corner: corner - 0.006, wall: 0.016, depth: 0.004, chamfer: 0.0015)
        lip.materials = [plastic]
        let lipNode = SCNNode(geometry: lip)
        lipNode.position = SCNVector3(Float(W / 2), 0, 0.0755)
        lidPivot.addChildNode(lipNode)
        let dimpleMat = SCNMaterial()
        dimpleMat.lightingModel = .constant
        dimpleMat.diffuse.contents = platform.plasticDark.withAlphaComponent(0.6)
        for (dx, dy) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
            let dimple = SCNPlane(width: 0.018, height: 0.018)
            dimple.cornerRadius = 0.009
            dimple.materials = [dimpleMat]
            let d = SCNNode(geometry: dimple)
            let cx: Float = Float(W / 2)
            let ox: Float = Float(dx) * Float(W / 2 - 0.022)
            let oy: Float = Float(dy) * Float(H / 2 - 0.022)
            d.position = SCNVector3(cx + ox, oy, 0.0778)
            lidPivot.addChildNode(d)
        }
        let coverPlane = SCNPlane(width: insert.width, height: insert.height)
        coverPlane.cornerRadius = 0.018
        coverPlane.materials = [Self.printed(cover)]
        let coverNode = SCNNode(geometry: coverPlane)
        coverNode.position = SCNVector3(Float(W / 2), 0, 0.0745)
        lidPivot.addChildNode(coverNode)
        if let stickers = placedStickerLayer(album, badges: badges, signature: signature,
                                             width: insert.width, height: insert.height) {
            stickers.position = SCNVector3(Float(W / 2), 0, 0.0751)
            lidPivot.addChildNode(stickers)
        }
        let film = Self.filmNode(width: W - 0.03, height: H - 0.03, z: 0.0758, flipped: false,
                                 platinum: badges.contains(.platinum))
        film.position.x = Float(W / 2)
        lidPivot.addChildNode(film)
        let inner = SCNPlane(width: W - 0.07, height: H - 0.07)
        inner.cornerRadius = 0.03
        inner.materials = [Self.printed(booklet ?? UIColor.darkGray)]
        let innerNode = SCNNode(geometry: inner)
        innerNode.eulerAngles.y = .pi
        innerNode.position = SCNVector3(Float(W / 2), 0, -0.0008)
        lidPivot.addChildNode(innerNode)
        parts.append(lidPivot)

        let node = AlbumNode(albumID: album.id, format: .game, signature: signature, parts: parts,
                             discPivot: extras ? makeDisc(album) : nil, reels: [], lidPivot: lidPivot)
        node.spineNodes = [spineNode, spineFilmNode]
        if !extras {
            let key: String = "reflect|" + signature
            let frame: UIColor = platform.plastic.withAlphaComponent(1)
            let inset: CGFloat = (W - insert.width) / 2 / W
            if let img = cached(key, { Self.reflectionImage(cover, frame: frame, inset: inset) }) {
                node.reflection = ReflectionFace(image: img, x: 0, width: W, height: H, z: 0.07)
            }
        }
        return node
    }

    static func reflectionImage(_ image: UIImage, frame: UIColor?, inset: CGFloat) -> UIImage? {
        let w: CGFloat = 220
        let ratio: CGFloat = image.size.width > 0 ? image.size.height / image.size.width : 1
        let h: CGFloat = frame == nil ? w : w * 1.152
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let size = CGSize(width: w, height: h)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            cg.translateBy(x: 0, y: h)
            cg.scaleBy(x: 1, y: -1)
            if let frame {
                frame.setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6).fill()
                let ix = w * inset
                let iw = w - 2 * ix
                let ih = min(h - 2 * ix, iw * ratio)
                image.draw(in: CGRect(x: ix, y: (h - ih) / 2, width: iw, height: ih))
            } else {
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            cg.scaleBy(x: 1, y: -1)
            cg.translateBy(x: 0, y: -h)
            let colors = [UIColor(white: 0, alpha: 0.30).cgColor, UIColor(white: 0, alpha: 0.10).cgColor, UIColor(white: 0, alpha: 0).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.28, 0.62]) {
                cg.setBlendMode(.destinationIn)
                cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: h), options: [.drawsAfterEndLocation])
            }
        }
    }

    static func filmNode(width: CGFloat, height: CGFloat, z: Float, flipped: Bool, platinum: Bool) -> SCNNode {
        let group = SCNNode()
        let film = SCNPlane(width: width, height: height)
        film.cornerRadius = 0.03
        let filmMat = glassy(strength: 0.6)
        if platinum { filmMat.shaderModifiers = [.fragment: iridescence] }
        film.materials = [filmMat]
        let filmNode = SCNNode(geometry: film)
        filmNode.renderingOrder = 11
        group.addChildNode(filmNode)
        let rim = SCNPlane(width: width, height: height)
        rim.cornerRadius = 0.03
        let rimMat = SCNMaterial()
        rimMat.lightingModel = .constant
        rimMat.diffuse.contents = filmRim
        rimMat.blendMode = .add
        rimMat.writesToDepthBuffer = false
        rim.materials = [rimMat]
        let rimNode = SCNNode(geometry: rim)
        rimNode.renderingOrder = 12
        rimNode.position.z = 0.0002
        group.addChildNode(rimNode)
        group.position.z = z
        if flipped { group.eulerAngles.y = .pi }
        group.categoryBitMask = 2
        filmNode.categoryBitMask = 2
        rimNode.categoryBitMask = 2
        return group
    }

    static let filmRim: UIImage = {
        let w: CGFloat = 540, h: CGFloat = 686
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor.black.cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            c.setStrokeColor(UIColor(white: 0.5, alpha: 1).cgColor)
            c.setLineWidth(3)
            c.stroke(CGRect(x: 2, y: 2, width: w - 4, height: h - 4))
            c.setStrokeColor(UIColor(white: 0.18, alpha: 1).cgColor)
            c.setLineWidth(6)
            c.stroke(CGRect(x: 7, y: 7, width: w - 14, height: h - 14))
            let colors = [UIColor(white: 0.22, alpha: 1).cgColor, UIColor.black.cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                c.drawRadialGradient(g, startCenter: CGPoint(x: w * 0.85, y: h * 0.1), startRadius: 0,
                                     endCenter: CGPoint(x: w * 0.85, y: h * 0.1), endRadius: w * 0.45, options: [])
            }
        }
    }()

    static func roundedSlab(width: CGFloat, height: CGFloat, corner: CGFloat, depth: CGFloat, chamfer: CGFloat,
                            mode: SCNChamferMode = .both) -> SCNGeometry {
        let path = UIBezierPath(roundedRect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height),
                                cornerRadius: corner)
        path.flatness = 0.002
        let shape = SCNShape(path: path, extrusionDepth: depth)
        shape.chamferRadius = chamfer
        shape.chamferMode = mode
        return shape
    }

    static func roundedFrame(width: CGFloat, height: CGFloat, corner: CGFloat, wall: CGFloat, depth: CGFloat, chamfer: CGFloat) -> SCNGeometry {
        let outer = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        let path = UIBezierPath(roundedRect: outer, cornerRadius: corner)
        path.append(UIBezierPath(roundedRect: outer.insetBy(dx: wall, dy: wall), cornerRadius: max(0.005, corner - wall)))
        path.usesEvenOddFillRule = true
        path.flatness = 0.002
        let shape = SCNShape(path: path, extrusionDepth: depth)
        shape.chamferRadius = chamfer
        shape.chamferMode = .both
        return shape
    }

    static func generatedGameCover(title: String, season: String, count: Int, platform: GamePlatform = .ps5) -> UIImage {
        let w: CGFloat = 1080, h: CGFloat = 1360
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            let c = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let sky = [UIColor(red: 0.03, green: 0.06, blue: 0.16, alpha: 1).cgColor,
                       UIColor(red: 0.06, green: 0.14, blue: 0.3, alpha: 1).cgColor,
                       UIColor(red: 0.02, green: 0.05, blue: 0.1, alpha: 1).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: space, colors: sky, locations: [0, 0.55, 1]) {
                c.drawLinearGradient(g, start: CGPoint(x: 0, y: 120), end: CGPoint(x: 0, y: h), options: [])
            }
            for (x, y) in [(180.0, 260.0), (900.0, 240.0), (540.0, 200.0)] {
                let glow = [UIColor(white: 1, alpha: 0.55).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray
                if let g = CGGradient(colorsSpace: space, colors: glow, locations: [0, 1]) {
                    c.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                                         endCenter: CGPoint(x: x, y: y), endRadius: 260, options: [])
                }
            }
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
            c.setFillColor(UIColor.white.cgColor)
            c.fillEllipse(in: CGRect(x: 780, y: 1150, width: 120, height: 120))
            c.setFillColor(UIColor(white: 0.1, alpha: 1).cgColor)
            c.fillEllipse(in: CGRect(x: 822, y: 1192, width: 36, height: 36))

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

            c.setFillColor(platform.bandFill.cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: 120))
            c.setFillColor(platform.bandLine.cgColor)
            c.fill(CGRect(x: 0, y: 118, width: w, height: 4))
            let band = (platform.label + "  ·  BANDE-SON") as NSString
            let bandAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 44, weight: .heavy),
                                                             .foregroundColor: platform.bandText, .kern: 4]
            band.draw(at: CGPoint(x: 48, y: 34), withAttributes: bandAttrs)
        }
    }

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

    static func gameSpine(title: String, platform: GamePlatform = .ps5) -> UIImage {
        let w: CGFloat = 136, h: CGFloat = 1650
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(white: 0.97, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            c.setFillColor(platform.bandFill.cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: 330))
            c.setFillColor((platform == .ps5 ? UIColor(red: 0.1, green: 0.3, blue: 0.85, alpha: 1) : platform.bandLine).cgColor)
            c.fill(CGRect(x: 0, y: 330, width: w, height: 4))
            let brand = NSAttributedString(string: platform.label, attributes: [
                .font: UIFont.systemFont(ofSize: 46, weight: .heavy),
                .foregroundColor: platform.bandText, .kern: 6
            ])
            c.saveGState()
            c.translateBy(x: w / 2, y: 165)
            c.rotate(by: .pi / 2)
            let bs = brand.size()
            brand.draw(at: CGPoint(x: -bs.width / 2, y: -bs.height / 2))
            c.restoreGState()
            let base = UIFont.systemFont(ofSize: 104, weight: .black)
            let italic = UIFont(descriptor: base.fontDescriptor.withSymbolicTraits([.traitItalic, .traitBold]) ?? base.fontDescriptor, size: 104)
            let titleText = NSAttributedString(string: title.uppercased(), attributes: [
                .font: italic, .foregroundColor: UIColor(white: 0.05, alpha: 1), .kern: -1,
                .strokeColor: UIColor(white: 0.05, alpha: 1), .strokeWidth: -4
            ])
            let ts = titleText.size()
            let shrink = min(1, 1000 / max(ts.width, 1))
            c.saveGState()
            c.translateBy(x: w / 2, y: 900)
            c.rotate(by: .pi / 2)
            c.scaleBy(x: shrink, y: shrink)
            titleText.draw(at: CGPoint(x: -ts.width / 2, y: -ts.height / 2))
            c.restoreGState()
            let ref = NSAttributedString(string: "PLAT\n0024", attributes: [
                .font: UIFont.systemFont(ofSize: 26, weight: .medium),
                .foregroundColor: UIColor(white: 0.15, alpha: 1)
            ])
            ref.draw(in: CGRect(x: 18, y: h - 120, width: w - 20, height: 80))
        }
    }

    static func gameBooklet(title: String, tracks: [(String, String)], platform: GamePlatform = .ps5) -> UIImage {
        let w: CGFloat = 1080, h: CGFloat = 1360
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(platform.trayDark.cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            c.setStrokeColor(platform.trayEdge.cgColor)
            c.setLineWidth(18)
            c.stroke(CGRect(x: 9, y: 9, width: w - 18, height: h - 18))
            let paper = CGRect(x: 90, y: 110, width: w - 170, height: h - 220)
            c.setFillColor(UIColor(red: 0.8, green: 0.86, blue: 1, alpha: 1).cgColor)
            c.fill(paper)
            let ink = UIColor(red: 0.12, green: 0.18, blue: 0.35, alpha: 1)
            let head: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 34, weight: .heavy), .foregroundColor: ink]
            let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 21, weight: .regular), .foregroundColor: ink]
            ("BANDE-SON ORIGINALE · " + title.uppercased() as NSString)
                .draw(in: CGRect(x: paper.minX + 50, y: paper.minY + 50, width: paper.width - 100, height: 44), withAttributes: head)
            var y = paper.minY + 120
            for (i, t) in tracks.prefix(18).enumerated() {
                let line: String = String(i + 1) + ". " + t.0 + " — " + t.1
                (line as NSString).draw(in: CGRect(x: paper.minX + 50, y: y, width: paper.width - 100, height: 28), withAttributes: body)
                y += 34
            }
            c.setFillColor(ink.withAlphaComponent(0.55).cgColor)
            y += 30
            var row = 0
            while y < paper.maxY - 60 {
                let jitter: CGFloat = CGFloat((row * 37) % 60)
                let full: CGFloat = paper.width - 100 - jitter
                let width: CGFloat = (row % 7 == 6) ? paper.width * 0.45 : full
                c.fill(CGRect(x: paper.minX + 50, y: y, width: width, height: 7))
                y += row % 7 == 6 ? 34 : 18
                row += 1
            }
            for cy in [180.0, Double(h) - 300] {
                let clip = CGRect(x: 60, y: CGFloat(cy), width: 140, height: 120)
                c.setFillColor(UIColor(red: 0.6, green: 0.75, blue: 1, alpha: 0.85).cgColor)
                c.fill(clip)
                c.setStrokeColor(UIColor(white: 1, alpha: 0.7).cgColor)
                c.setLineWidth(4)
                c.stroke(clip.insetBy(dx: 8, dy: 8))
            }
        }
    }

    static func gameTray(_ platform: GamePlatform) -> UIImage {
        let w: CGFloat = 810, h: CGFloat = 1020
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            let c = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let bg = [platform.trayLight.cgColor, platform.trayDark.cgColor] as CFArray
            if let g = CGGradient(colorsSpace: space, colors: bg, locations: [0, 1]) {
                c.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
            }
            c.setStrokeColor(platform.trayEdge.cgColor)
            c.setLineWidth(26)
            c.stroke(CGRect(x: 13, y: 13, width: w - 26, height: h - 26))
            c.setStrokeColor(UIColor(white: 1, alpha: 0.5).cgColor)
            c.setLineWidth(3)
            c.stroke(CGRect(x: 34, y: 34, width: w - 68, height: h - 68))
            c.setStrokeColor(UIColor(white: 1, alpha: 0.75).cgColor)
            c.setLineWidth(4)
            c.strokeLineSegments(between: [CGPoint(x: 110, y: 90), CGPoint(x: w - 110, y: 90),
                                           CGPoint(x: 110, y: h - 90), CGPoint(x: w - 110, y: h - 90)])
            let center = CGPoint(x: w / 2, y: h / 2)
            let r: CGFloat = 368
            c.setStrokeColor(UIColor(red: 0.2, green: 0.38, blue: 0.9, alpha: 0.9).cgColor)
            c.setLineWidth(16)
            c.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            c.setStrokeColor(UIColor(white: 1, alpha: 0.55).cgColor)
            c.setLineWidth(4)
            c.strokeEllipse(in: CGRect(x: center.x - r + 12, y: center.y - r + 12, width: 2 * r - 24, height: 2 * r - 24))
            c.setFillColor(UIColor(red: 0.36, green: 0.52, blue: 0.95, alpha: 1).cgColor)
            for dx in [-r - 6, r - 40] {
                c.fill(CGRect(x: center.x + dx, y: center.y - 90, width: 46, height: 180))
            }
            let hub: CGFloat = 92
            c.setFillColor(UIColor(red: 0.62, green: 0.75, blue: 1, alpha: 1).cgColor)
            c.fillEllipse(in: CGRect(x: center.x - hub, y: center.y - hub, width: 2 * hub, height: 2 * hub))
            c.setStrokeColor(UIColor(white: 1, alpha: 0.9).cgColor)
            c.setLineWidth(5)
            c.setLineCap(.round)
            for k in 0..<6 {
                let a = CGFloat(k) / 6 * 2 * .pi + .pi / 6
                let ca: CGFloat = cos(a), sa: CGFloat = sin(a)
                let from = CGPoint(x: center.x + ca * 26, y: center.y + sa * 26)
                let to = CGPoint(x: center.x + ca * 82, y: center.y + sa * 82)
                c.strokeLineSegments(between: [from, to])
            }
            c.setFillColor(UIColor(red: 0.25, green: 0.42, blue: 0.92, alpha: 1).cgColor)
            c.fillEllipse(in: CGRect(x: center.x - 24, y: center.y - 24, width: 48, height: 48))
        }
    }

    static func gameDiscLabel(_ cover: UIImage, title: String, band: UIColor = UIColor(white: 0.97, alpha: 1)) -> UIImage {
        let base = discLabel(cover)
        let size = base.size
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            base.draw(at: .zero)
            let R = size.width / 2
            c.saveGState()
            let printArea = UIBezierPath(ovalIn: CGRect(x: R - R * 0.985, y: R - R * 0.985, width: 2 * R * 0.985, height: 2 * R * 0.985))
            printArea.append(UIBezierPath(ovalIn: CGRect(x: R - R * 0.36, y: R - R * 0.36, width: 2 * R * 0.36, height: 2 * R * 0.36)).reversing())
            c.addPath(printArea.cgPath)
            c.clip()
            c.setFillColor(band.cgColor)
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

    // MARK: Cassette

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

        if let stickers = stickerLayer(album, badges: [], signature: signature, onlyCustom: true) {
            stickers.position = SCNVector3(0.28, -0.06, Float(D / 2) + 0.0015)
            stickers.scale = SCNVector3(0.62, 0.62, 0.62)
            parts.append(stickers)
        }

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

        let glass = SCNPlane(width: W * 0.5, height: H * 0.21)
        glass.cornerRadius = H * 0.05
        glass.materials = [Self.glassy(strength: 0.8)]
        let glassNode = SCNNode(geometry: glass)
        glassNode.position = SCNVector3(0, Float(0.055 * Double(H)), Float(D / 2) + 0.006)
        glassNode.renderingOrder = 10
        parts.append(glassNode)

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

    static func printed(_ contents: Any) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = contents
        m.multiply.contents = UIColor(white: 0.94, alpha: 1)
        return m
    }

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

    static let iridescence = """
    #pragma body
    float3 v = normalize(_surface.view);
    float3 n = normalize(_surface.normal);
    float facing = saturate(dot(v, n));
    float phase = facing * 2.2 + _surface.diffuseTexcoord.x * 1.6 + _surface.diffuseTexcoord.y * 0.8;
    float3 rainbow = 0.5 + 0.5 * cos(6.28318 * (phase + float3(0.0, 0.33, 0.67)));
    _output.color.rgb += rainbow * 0.12 * (1.1 - facing);
    """

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

struct CoverFace: View {
    let album: AlbumInfo
    let badges: [AlbumBadge]
    @Environment(Library.self) private var library

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                if let front = library.extraImage("front", album.id) {
                    Image(uiImage: front).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    ArtworkView(track: album.first, animated: false, cornerRadius: 0)
                }
                if badges.contains(.platinum) { HoloSheen(light: -0.2) }
                PlacedStickers(album: album, badges: badges, size: geo.size)
            }
        }
    }
}

// MARK: - Studio

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

extension GamePlatform {
    var plastic: UIColor {
        switch self {
        case .ps3: return UIColor(red: 0.86, green: 0.9, blue: 0.95, alpha: 0.42)
        case .ps4: return UIColor(red: 0.04, green: 0.24, blue: 0.72, alpha: 0.9)
        case .ps5: return UIColor(red: 0.12, green: 0.36, blue: 0.92, alpha: 0.92)
        }
    }
    var plasticDark: UIColor {
        switch self {
        case .ps3: return UIColor(white: 0.55, alpha: 0.8)
        case .ps4: return UIColor(red: 0.02, green: 0.12, blue: 0.45, alpha: 0.95)
        case .ps5: return UIColor(red: 0.05, green: 0.17, blue: 0.58, alpha: 0.95)
        }
    }
    var trayLight: UIColor {
        switch self {
        case .ps3: return UIColor(red: 0.86, green: 0.88, blue: 0.9, alpha: 1)
        case .ps4: return UIColor(red: 0.38, green: 0.52, blue: 0.86, alpha: 1)
        case .ps5: return UIColor(red: 0.55, green: 0.68, blue: 0.97, alpha: 1)
        }
    }
    var trayDark: UIColor {
        switch self {
        case .ps3: return UIColor(red: 0.76, green: 0.78, blue: 0.81, alpha: 1)
        case .ps4: return UIColor(red: 0.28, green: 0.42, blue: 0.8, alpha: 1)
        case .ps5: return UIColor(red: 0.47, green: 0.61, blue: 0.95, alpha: 1)
        }
    }
    var trayEdge: UIColor {
        switch self {
        case .ps3: return UIColor(white: 0.62, alpha: 1)
        case .ps4: return UIColor(red: 0.06, green: 0.24, blue: 0.7, alpha: 1)
        case .ps5: return UIColor(red: 0.18, green: 0.36, blue: 0.92, alpha: 1)
        }
    }
    var bandFill: UIColor {
        switch self {
        case .ps3: return UIColor(white: 0.06, alpha: 1)
        case .ps4: return UIColor(red: 0.0, green: 0.27, blue: 0.68, alpha: 1)
        case .ps5: return UIColor(white: 0.96, alpha: 1)
        }
    }
    var bandText: UIColor { self == .ps5 ? UIColor(white: 0.1, alpha: 1) : .white }
    var bandLine: UIColor {
        switch self {
        case .ps3: return UIColor(white: 0.45, alpha: 1)
        case .ps4: return UIColor(white: 1, alpha: 0.85)
        case .ps5: return UIColor(white: 0.8, alpha: 1)
        }
    }
}

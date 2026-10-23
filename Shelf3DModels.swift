import SwiftUI
import SceneKit
import UIKit

// MARK: - Dimensions réelles (en unités de scène)

enum Physical {
    /// Boîtier CD : 142 × 125 × 10 mm. Cassette : 100 × 63 × 12 mm (agrandie à la largeur du CD).
    static func size(_ format: AlbumFormat) -> SCNVector3 {
        format == .cd ? SCNVector3(1.42, 1.25, 0.1) : SCNVector3(1.42, 0.899, 0.17)
    }
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
    private(set) var spinning = false
    private(set) var discOut = false

    var size: SCNVector3 { Physical.size(format) }

    init(albumID: String, format: AlbumFormat, signature: String, parts: [SCNNode], discPivot: SCNNode?, reels: [SCNNode]) {
        self.albumID = albumID
        self.format = format
        self.signature = signature
        self.discPivot = discPivot
        self.reels = reels
        root.addChildNode(body)
        for p in parts { body.addChildNode(p) }
        if let discPivot { root.addChildNode(discPivot) }
        for r in reels { body.addChildNode(r) }
    }

    /// Le disque n'est fabriqué qu'au besoin (ouverture plus rapide).
    var hasDisc: Bool { discPivot != nil }

    func attachDisc(_ pivot: SCNNode) {
        guard discPivot == nil else { return }
        discPivot = pivot
        root.addChildNode(pivot)
        if spinning {
            pivot.runAction(.repeatForever(.rotateBy(x: 0, y: 0, z: -2 * .pi, duration: 1.8)), forKey: "spin")
        }
    }

    /// Remet l'objet au repos sans animation.
    func settle() {
        guard let discPivot else { return }
        discOut = false
        discPivot.position = SCNVector3(0.05, 0, 0)
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
        let art = library.artworkURL(album.first)?.lastPathComponent ?? "-"
        return [album.id, format.rawValue, art, badges.map(\.rawValue).joined(separator: ","), album.title, album.artist].joined(separator: "|")
    }

    func make(_ album: AlbumInfo, format: AlbumFormat, badges: [AlbumBadge], extras: Bool) -> AlbumNode {
        let sig = signature(album, format, badges)
        switch format {
        case .cd: return makeCD(album, badges: badges, extras: extras, signature: sig)
        case .cassette: return makeCassette(album, badges: badges, signature: sig)
        }
    }

    // MARK: Boîtier CD : plateau fumé, pochette glissée sous un couvercle cristal, charnière.

    private func makeCD(_ album: AlbumInfo, badges: [AlbumBadge], extras: Bool, signature: String) -> AlbumNode {
        let size = Physical.size(.cd)
        let W = CGFloat(size.x), H = CGFloat(size.y), D = CGFloat(size.z)
        var parts: [SCNNode] = []

        // Plateau : noir fumé, le dos porte la jaquette arrière.
        let backImage = cached("back|" + signature) { render(CDBackInsert(album: album, lightX: 0), CGSize(width: 568, height: 500)) }
        let tray = SCNBox(width: W, height: H, length: D - 0.014, chamferRadius: 0.01)
        let smoke = Self.plastic(UIColor(white: 0.1, alpha: 1), roughness: 0.45, coat: 0.2)
        let black = Self.plastic(UIColor(white: 0.03, alpha: 1), roughness: 0.5, coat: 0.1)
        tray.materials = [black, smoke, Self.printed(backImage ?? UIColor.darkGray), smoke, smoke, smoke]
        let trayNode = SCNNode(geometry: tray)
        trayNode.position.z = -0.007
        parts.append(trayNode)

        // Pochette : un carré de 120 mm glissé sous le couvercle, décalé vers la droite.
        let cover = SCNPlane(width: 1.2, height: 1.2)
        let coverImage = cached("cover|" + signature) { render(CoverFace(album: album, badges: badges), CGSize(width: 600, height: 600)) }
        // Couleurs exactes de la pochette : elle n'est pas « brûlée » par les lumières.
        cover.materials = [Self.printed(coverImage ?? UIColor.darkGray)]
        let coverNode = SCNNode(geometry: cover)
        coverNode.position = SCNVector3(Float(W / 2 - 0.62), 0, Float(D / 2 - 0.0135))
        parts.append(coverNode)

        // Charnière : la bande noire striée à gauche, et ses deux axes arrondis.
        let hingeBand = SCNBox(width: 0.16, height: H - 0.02, length: 0.006, chamferRadius: 0.002)
        hingeBand.materials = [Self.plastic(Self.ridges, roughness: 0.4, coat: 0.15)]
        let bandNode = SCNNode(geometry: hingeBand)
        bandNode.position = SCNVector3(Float(-W / 2 + 0.1), 0, Float(D / 2 - 0.015))
        parts.append(bandNode)
        for y in [-1.0, 1.0] {
            let pin = SCNCylinder(radius: 0.022, height: 0.18)
            pin.materials = [Self.plastic(UIColor(white: 0.08, alpha: 1), roughness: 0.3, coat: 0.3)]
            let pinNode = SCNNode(geometry: pin)
            pinNode.position = SCNVector3(Float(-W / 2 + 0.018), Float(y * Double(H / 2 - 0.12)), Float(D / 2 - 0.02))
            parts.append(pinNode)
        }

        // Couvercle : plastique cristal parfaitement transparent, qui n'ajoute que les reflets.
        let lid = SCNBox(width: W, height: H, length: 0.012, chamferRadius: 0.006)
        let clear = Self.glassy(strength: 0.55)
        if badges.contains(.platinum) { clear.shaderModifiers = [.fragment: Self.iridescence] }
        let lidEdge = Self.glassy(strength: 0.9)
        lid.materials = [clear, lidEdge, clear, lidEdge, lidEdge, lidEdge]
        let lidNode = SCNNode(geometry: lid)
        lidNode.position.z = Float(D / 2 - 0.006)
        lidNode.renderingOrder = 10
        parts.append(lidNode)

        return AlbumNode(albumID: album.id, format: .cd, signature: signature, parts: parts,
                         discPivot: extras ? makeDisc(album) : nil, reels: [])
    }

    /// Le CD lui-même, rangé (invisible) dans le boîtier.
    func makeDisc(_ album: AlbumInfo) -> SCNNode {
        let disc = SCNCylinder(radius: 0.58, height: 0.012)
        let silver = Self.plastic(UIColor(white: 0.82, alpha: 1), roughness: 0.25, coat: 0.3)
        silver.metalness.contents = 0.8
        let image = cached("disc|" + album.id + "|" + album.title) {
            render(CDDisc(album: album, spinning: false), CGSize(width: 512, height: 512), scale: 1.2)
        }
        let print = Self.plastic(image ?? UIColor.lightGray, roughness: 0.3, coat: 0.3)
        print.metalness.contents = 0.25
        // Ordre des faces d'un cylindre : côté, dessus, dessous.
        disc.materials = [silver, print, silver]
        let discNode = SCNNode(geometry: disc)
        discNode.eulerAngles.x = .pi / 2
        let pivot = SCNNode()
        pivot.addChildNode(discNode)
        pivot.position = SCNVector3(0.05, 0, 0)
        pivot.opacity = 0
        return pivot
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
            floor.reflectionResolutionScaleFactor = 0.35
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

import SwiftUI
import SceneKit
import UIKit

// MARK: - Dimensions réelles (en mètres « de scène »)

enum Physical {
    /// Boîtier CD : 142 × 125 × 10 mm. Cassette : 100 × 63 × 12 mm (agrandie à la largeur du CD).
    static func size(_ format: AlbumFormat) -> SCNVector3 {
        format == .cd ? SCNVector3(1.42, 1.25, 0.1) : SCNVector3(1.42, 0.899, 0.17)
    }
}

// MARK: - Un album en 3D

/// Le modèle 3D d'un album : le boîtier (ou la cassette), et selon le format le disque ou les bobines.
final class AlbumNode {
    let albumID: String
    let format: AlbumFormat
    let signature: String
    /// Placé par la mise en page (carrousel ou vue en main).
    let root = SCNNode()
    let body: SCNNode
    let discPivot: SCNNode?
    let reels: [SCNNode]
    private(set) var spinning = false
    private(set) var discOut = false

    var size: SCNVector3 { Physical.size(format) }

    init(albumID: String, format: AlbumFormat, signature: String, body: SCNNode, discPivot: SCNNode?, reels: [SCNNode]) {
        self.albumID = albumID
        self.format = format
        self.signature = signature
        self.body = body
        self.discPivot = discPivot
        self.reels = reels
        root.addChildNode(body)
        if let discPivot { body.addChildNode(discPivot) }
        for r in reels { body.addChildNode(r) }
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

    /// Fait glisser le CD hors du boîtier (ou le range).
    func setDiscOut(_ out: Bool, animated: Bool = true) {
        guard let discPivot, out != discOut else { return }
        discOut = out
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.75 : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        discPivot.position = out ? SCNVector3(0.98, -0.06, 0.05) : SCNVector3(0.07, 0, 0)
        discPivot.opacity = out ? 1 : 0
        body.position = out ? SCNVector3(-0.42, 0, 0) : SCNVector3(0, 0, 0)
        SCNTransaction.commit()
    }
}

// MARK: - Fabrication des modèles

/// Dessine les faces (pochette, dos, étiquette de cassette, disque) avec les vues 2D, puis en fait des volumes.
@MainActor
struct AlbumNodeBuilder {
    let library: Library
    let settings: AppSettings

    func signature(_ album: AlbumInfo, _ format: AlbumFormat, _ badges: [AlbumBadge]) -> String {
        let art = library.artworkURL(album.first)?.lastPathComponent ?? "-"
        return [album.id, format.rawValue, art, badges.map(\.rawValue).joined(separator: ","), album.title, album.artist].joined(separator: "|")
    }

    func make(_ album: AlbumInfo, format: AlbumFormat, badges: [AlbumBadge], extras: Bool) -> AlbumNode {
        let size = Physical.size(format)
        let w = CGFloat(size.x), h = CGFloat(size.y), d = CGFloat(size.z)
        let texW: CGFloat = 640
        let texH = texW * h / w

        let box = SCNBox(width: w, height: h, length: d, chamferRadius: format == .cd ? 0.012 : 0.028)
        let sig = signature(album, format, badges)

        let front: UIImage?
        let back: UIImage?
        switch format {
        case .cd:
            front = render(CDCaseView(album: album, showBack: false, lightX: -0.3, lightY: 0, animated: false, badges: badges),
                           CGSize(width: texW, height: texH))
            back = render(CDBackInsert(album: album, lightX: 0), CGSize(width: texW, height: texH))
        case .cassette:
            front = render(CassetteView(album: album, sideB: false, spinning: false, progress: 0, lightX: -0.3, badges: badges),
                           CGSize(width: texW, height: texH))
            back = render(CassetteView(album: album, sideB: true, spinning: false, progress: 0, lightX: -0.3, badges: []),
                          CGSize(width: texW, height: texH))
        }

        let frontMat = Self.plastic(front ?? UIColor.darkGray, roughness: 0.35)
        let backMat = Self.plastic(back ?? UIColor.darkGray, roughness: 0.35)
        if badges.contains(.platinum) { frontMat.shaderModifiers = [.fragment: Self.iridescence] }

        let edge: SCNMaterial
        let spine: SCNMaterial
        if format == .cd {
            // Tranches en plastique cristal, charnière noire à gauche.
            edge = Self.plastic(UIColor(white: 0.78, alpha: 1), roughness: 0.15)
            edge.transparency = 0.9
            spine = Self.plastic(UIColor(white: 0.06, alpha: 1), roughness: 0.3)
        } else {
            // Plastique fumé de la cassette.
            edge = Self.plastic(UIColor(white: 0.13, alpha: 1), roughness: 0.45)
            spine = edge
        }
        // Ordre des faces d'un SCNBox : avant, droite, arrière, gauche, haut, bas.
        box.materials = [frontMat, edge, backMat, spine, edge, edge]

        let body = SCNNode(geometry: box)
        body.castsShadow = true

        var discPivot: SCNNode?
        var reels: [SCNNode] = []

        if extras && format == .cd {
            let disc = SCNCylinder(radius: 0.58, height: 0.012)
            let silver = Self.plastic(UIColor(white: 0.85, alpha: 1), roughness: 0.15)
            silver.metalness.contents = 0.9
            let print = Self.plastic(render(CDDisc(album: album, spinning: false), CGSize(width: 600, height: 600)) ?? UIColor.lightGray,
                                     roughness: 0.2)
            print.metalness.contents = 0.35
            // Ordre des faces d'un cylindre : côté, dessus, dessous.
            disc.materials = [silver, print, silver]
            let discNode = SCNNode(geometry: disc)
            discNode.eulerAngles.x = .pi / 2
            discNode.castsShadow = true
            let pivot = SCNNode()
            pivot.addChildNode(discNode)
            pivot.position = SCNVector3(0.07, 0, 0)
            pivot.opacity = 0
            discPivot = pivot
        }

        if format == .cassette {
            // Les deux moyeux de la fenêtre, qui tournent pendant la lecture.
            let hub = Self.plastic(Self.reelImage, roughness: 0.4)
            for side in [-1.0, 1.0] {
                let reel = SCNCylinder(radius: 0.044 * h / 0.899, height: 0.004)
                reel.materials = [hub, hub, hub]
                let reelNode = SCNNode(geometry: reel)
                reelNode.eulerAngles.x = .pi / 2
                let pivot = SCNNode()
                pivot.addChildNode(reelNode)
                pivot.position = SCNVector3(Float(side) * 0.2535 * Float(w / 1.42), 0.0494 * Float(h / 0.899), Float(d / 2) + 0.003)
                reels.append(pivot)
            }
        }

        return AlbumNode(albumID: album.id, format: format, signature: sig, body: body, discPivot: discPivot, reels: reels)
    }

    private func render<V: View>(_ view: V, _ size: CGSize) -> UIImage? {
        let content = view
            .frame(width: size.width, height: size.height)
            .environment(library)
            .environment(settings)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return renderer.uiImage
    }

    /// Plastique physique avec un vernis brillant (reflets nets de l'éclairage).
    static func plastic(_ contents: Any, roughness: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = contents
        m.roughness.contents = roughness
        m.metalness.contents = 0.0
        m.clearCoat.contents = 1.0
        m.clearCoatRoughness.contents = 0.05
        return m
    }

    /// Reflet arc-en-ciel qui change selon l'angle de vue (albums disque de platine).
    static let iridescence = """
    #pragma body
    float3 v = normalize(_surface.view);
    float3 n = normalize(_surface.normal);
    float facing = saturate(dot(v, n));
    float phase = facing * 2.2 + _surface.diffuseTexcoord.x * 1.6 + _surface.diffuseTexcoord.y * 0.8;
    float3 rainbow = 0.5 + 0.5 * cos(6.28318 * (phase + float3(0.0, 0.33, 0.67)));
    _output.color.rgb += rainbow * 0.16 * (1.15 - facing);
    """

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
}

// MARK: - Studio : lumières, reflets, sol

enum Studio {
    /// Image d'environnement : deux softbox et un plafond doux, pour des reflets de studio photo.
    static let environment: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 512)).image { ctx in
            let c = ctx.cgContext
            let colors = [UIColor(white: 0.2, alpha: 1).cgColor, UIColor(white: 0.03, alpha: 1).cgColor] as CFArray
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            c.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: 512), options: [])
            c.setFillColor(UIColor(white: 1, alpha: 0.95).cgColor)
            c.fill(CGRect(x: 120, y: 120, width: 170, height: 120))
            c.fill(CGRect(x: 640, y: 90, width: 120, height: 170))
            c.setFillColor(UIColor(white: 1, alpha: 0.35).cgColor)
            c.fill(CGRect(x: 380, y: 10, width: 260, height: 40))
        }
    }()

    static func addLights(to scene: SCNScene, withFloor: Bool) {
        scene.lightingEnvironment.contents = environment
        scene.lightingEnvironment.intensity = 1.4

        let key = SCNLight()
        key.type = .directional
        key.intensity = 900
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowColor = UIColor(white: 0, alpha: 0.55)
        key.shadowRadius = 10
        key.shadowSampleCount = 16
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.85, 0.45, 0)
        keyNode.name = "key"
        scene.rootNode.addChildNode(keyNode)

        let rim = SCNLight()
        rim.type = .omni
        rim.intensity = 350
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.position = SCNVector3(-3, 2.5, -2.5)
        scene.rootNode.addChildNode(rimNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 120
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        if withFloor {
            // Projecteur coloré par la pochette, et sol miroir qui reflète les boîtiers.
            let spot = SCNLight()
            spot.type = .spot
            spot.intensity = 700
            spot.spotInnerAngle = 25
            spot.spotOuterAngle = 70
            let spotNode = SCNNode()
            spotNode.light = spot
            spotNode.name = "spot"
            spotNode.position = SCNVector3(0, 3.2, 1.6)
            spotNode.look(at: SCNVector3(0, 0, 0))
            scene.rootNode.addChildNode(spotNode)

            let floor = SCNFloor()
            floor.reflectivity = 0.28
            floor.reflectionFalloffEnd = 1.4
            floor.reflectionResolutionScaleFactor = 0.6
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = UIColor(white: 0.04, alpha: 1)
            m.roughness.contents = 0.6
            floor.materials = [m]
            scene.rootNode.addChildNode(SCNNode(geometry: floor))

            let bg = UIColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1)
            scene.background.contents = bg
            scene.fogColor = bg
            scene.fogStartDistance = 6
            scene.fogEndDistance = 13
        }
    }
}

extension SCNView {
    func configureForShelf() {
        backgroundColor = .clear
        isOpaque = false
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 120
        rendersContinuously = true
        isPlaying = true
        isJitteringEnabled = false
    }
}

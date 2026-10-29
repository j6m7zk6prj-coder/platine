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
        // Pochette de 33 tours : 315 × 315 mm.
        case .vinyl: return SCNVector3(3.15, 3.15, 0.04)
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

@MainActor
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
    /// Le blister : film plastique d'un CD neuf, retiré seulement avec le bouton « Déballer ».
    var wrapNode: SCNNode?
    /// Appelé quand le blister est retiré (pour s'en souvenir).
    var onUnwrap: () -> Void = {}
    /// Pièces propres aux vinyles (sous-pochette, gatefold, double disque).
    var vinyl: VinylRig?

    /// Affiche ou cache le blister, sans animation (mise à jour de l'étagère).
    func setWrapVisible(_ on: Bool) {
        guard let wrapNode, wrapNode.action(forKey: "unwrap") == nil else { return }
        wrapNode.isHidden = !on
        wrapNode.opacity = 1
        wrapNode.scale = SCNVector3(1, 1, 1)
        wrapNode.position = SCNVector3(0, 0, 0)
        wrapNode.eulerAngles = SCNVector3(0, 0, 0)
    }

    /// Le blister est-il encore sur le boîtier ?
    var isWrapped: Bool { wrapNode.map { !$0.isHidden && $0.action(forKey: "unwrap") == nil } ?? false }

    /// Déballer : le film se détend, se décolle par un coin, puis glisse hors du boîtier en se froissant.
    func unwrap() {
        guard let wrapNode, isWrapped else { return }
        onUnwrap()
        // Les distances suivent la taille de l'objet (une pochette de vinyle est bien plus grande qu'un CD).
        let k = Double(size.x / 1.42)
        // 1. Le film se détend (on vient de tirer la languette).
        let loosen = SCNAction.scale(to: 1.018, duration: 0.16)
        loosen.timingMode = .easeOut
        // 2. Il se décolle du coin droit, en pivotant un peu.
        let peel = SCNAction.group([
            .rotateBy(x: 0.05, y: -0.32, z: -0.06, duration: 0.34),
            .moveBy(x: 0.12 * k, y: 0.06 * k, z: 0.16 * k, duration: 0.34)
        ])
        peel.timingMode = .easeInEaseOut
        // 3. Il part sur le côté et s'efface.
        let away = SCNAction.group([
            .moveBy(x: 1.1 * k, y: 0.3 * k, z: 0.5 * k, duration: 0.5),
            .rotateBy(x: 0.1, y: -0.55, z: -0.18, duration: 0.5),
            .scale(to: 0.92, duration: 0.5),
            .fadeOut(duration: 0.5)
        ])
        away.timingMode = .easeIn
        wrapNode.runAction(.sequence([loosen, peel, away, .hide(), .run { node in
            // Remis en place (caché) pour la prochaine fois qu'il reviendra.
            node.opacity = 1
            node.scale = SCNVector3(1, 1, 1)
            node.position = SCNVector3(0, 0, 0)
            node.eulerAngles = SCNVector3(0, 0, 0)
        }]), forKey: "unwrap")
    }

    var size: SCNVector3 { Physical.size(format) }
    /// Échelle d'affichage (le boîtier de jeu est réduit pour avoir la même présence qu'un CD).
    var fit: Float {
        switch format {
        case .game: return 0.78
        case .vinyl: return 0.47
        default: return 1
        }
    }
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
        if format == .vinyl { return SCNVector3(0, 0, 0) }
        return format == .game ? SCNVector3(0, 0.02, Physical.gameDiscZ) : SCNVector3(0.05, 0, 0)
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
        if vinyl != nil { settleVinyl() }
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
        // Un vinyle tenu en main ne tourne pas.
        let disc: SCNNode? = vinyl != nil ? nil : discPivot
        let spinners = reels + (disc.map { [$0] } ?? [])
        for node in spinners {
            if on {
                // 33 tours par minute : un tour en 1,8 seconde.
                let duration = node === disc ? 1.8 : 2.4
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
        // Vinyle : géré par ses étapes (pochette, sorti, platine).
        guard vinyl == nil, let discPivot, out != discOut else { return }
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
    /// Vue « en main » : textures en haute définition (le carrousel garde des textures plus légères).
    var hiRes = false

    /// Échelle de rendu des faces dessinées : bien plus fine quand l'objet est tenu en main.
    var faceScale: CGFloat { hiRes ? 3.4 : 2.0 }

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
        // Étiquette prix, et pour un vinyle : ses options, l'intérieur du gatefold et l'usure de la pochette.
        var extra: String = settings.priceStickers ? library.priceLabel(for: album).key : "noprice"
        if format == .vinyl {
            let options = library.vinylOptions(album.id)
            let inner: String = library.extraImageName("inner", album.id) ?? "-"
            let wear: Int = settings.ringWear ? Int((library.ringWear(album) * 4).rounded()) : 0
            extra += "#" + options.signature + "#" + inner + "#" + String(wear) + "#" + String(album.tracks.count)
        }
        let parts: [String] = [album.id, format.rawValue, art, badgeList, album.title, album.artist, extra, hiRes ? "hd" : "sd"]
        return parts.joined(separator: "|")
    }

    func make(_ album: AlbumInfo, format: AlbumFormat, badges: [AlbumBadge], extras: Bool) -> AlbumNode {
        let sig = signature(album, format, badges)
        switch format {
        case .cd:
            let node = makeCD(album, badges: badges, extras: extras, signature: sig)
            node.wrapNode?.isHidden = !(settings.shrinkWrap && library.isSealed(album.id))
            let lib = library
            let id = album.id
            node.onUnwrap = { lib.setSealed(id, false) }
            return node
        case .cassette: return makeCassette(album, badges: badges, signature: sig)
        case .game: return makeGameCase(album, badges: badges, extras: extras, signature: sig)
        case .vinyl:
            let node = makeVinyl(album, badges: badges, signature: sig)
            node.wrapNode?.isHidden = !(settings.shrinkWrap && library.isSealed(album.id))
            let lib = library
            let id = album.id
            node.onUnwrap = { lib.setSealed(id, false) }
            return node
        }
    }

    // MARK: Boîtier CD : plateau fumé, pochette glissée sous un couvercle cristal, charnière.

    private func makeCD(_ album: AlbumInfo, badges: [AlbumBadge], extras: Bool, signature: String) -> AlbumNode {
        let size = Physical.size(.cd)
        let W = CGFloat(size.x), H = CGFloat(size.y), D = CGFloat(size.z)
        var parts: [SCNNode] = []

        // Plateau : noir fumé, le dos porte la jaquette arrière.
        let backImage = cached("back|" + signature) {
            render(CDBackInsert(album: album, lightX: 0), CGSize(width: 568, height: 500), scale: faceScale)
        }
        let spine = cached("spine|" + signature) {
            Self.spineImage(title: album.title, artist: album.artist, color: UIColor(library.palette(for: album.cover)[0]))
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
            render(CoverFace(album: album, badges: badges), CGSize(width: 600, height: 600), scale: faceScale)
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
        // Bords en plastique transparent un peu rugueux, légèrement laiteux, comme un vrai boîtier.
        let lidEdge = SCNMaterial()
        lidEdge.lightingModel = .physicallyBased
        // Le polystyrène des vrais boîtiers est légèrement vert d'eau sur la tranche.
        lidEdge.diffuse.contents = UIColor(red: 0.8, green: 0.9, blue: 0.88, alpha: 0.62)
        lidEdge.roughness.contents = Self.plasticGrain
        lidEdge.roughness.intensity = 1
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

        // Le plastique vit : petites bulles prises dans le cristal, micro-rayures et poussières.
        let wear = SCNPlane(width: W - 0.01, height: H - 0.01)
        let wearMat = SCNMaterial()
        wearMat.lightingModel = .constant
        wearMat.diffuse.contents = Self.plasticWear
        wearMat.blendMode = .add
        wearMat.writesToDepthBuffer = false
        wear.materials = [wearMat]
        let wearNode = SCNNode(geometry: wear)
        wearNode.position.z = Float(D / 2) + 0.0011
        wearNode.renderingOrder = 12
        parts.append(wearNode)

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

        // Étiquette prix du disquaire, collée en haut à droite.
        if settings.priceStickers {
            // Étiquette d'étiqueteuse : 26 × 16 mm, collée en haut à droite.
            let tag = Self.priceTagNode(library.priceLabel(for: album), width: 0.26)
            tag.position = SCNVector3(Float(W / 2 - 0.22), Float(H / 2 - 0.14), Float(D / 2) + 0.0046)
            tag.eulerAngles.z = -0.04
            parts.append(tag)
        }

        // Blister : le film plastique bien tendu d'un CD neuf, avec ses plis aux coins, ses soudures au dos
        // et la bande de sécurité sur le dessus. Il ne voile pas la pochette : il n'ajoute que des reflets.
        let wrap = SCNNode()
        let film = SCNBox(width: W + 0.005, height: H + 0.005, length: D + 0.006, chamferRadius: 0.0045)
        film.materials = [Self.shrinkFilm(Self.shrinkFront), Self.shrinkFilm(Self.shrinkSide),
                          Self.shrinkFilm(Self.shrinkBack), Self.shrinkFilm(Self.shrinkSide),
                          Self.shrinkFilm(Self.shrinkSide), Self.shrinkFilm(Self.shrinkSide)]
        let filmNode = SCNNode(geometry: film)
        filmNode.renderingOrder = 13
        wrap.addChildNode(filmNode)
        // Bande de sécurité collée sur le dessus, qui déborde un peu sur la face avant.
        let strip = SCNPlane(width: 0.46, height: D + 0.004)
        let stripMat = SCNMaterial()
        stripMat.lightingModel = .physicallyBased
        stripMat.diffuse.contents = Self.securityStrip(album.title)
        stripMat.roughness.contents = 0.35
        strip.materials = [stripMat]
        let stripNode = SCNNode(geometry: strip)
        stripNode.eulerAngles.x = -.pi / 2
        stripNode.position = SCNVector3(0.05, Float(H / 2 + 0.0032), 0)
        wrap.addChildNode(stripNode)
        let lip = SCNPlane(width: 0.46, height: 0.07)
        let lipMat = SCNMaterial()
        lipMat.lightingModel = .physicallyBased
        lipMat.diffuse.contents = Self.securityStrip(album.title)
        lipMat.diffuse.contentsTransform = SCNMatrix4MakeScale(1, 0.35, 1)
        lipMat.roughness.contents = 0.35
        lip.materials = [lipMat]
        let lipNode = SCNNode(geometry: lip)
        lipNode.position = SCNVector3(0.05, Float(H / 2 - 0.035), Float(D / 2 + 0.0031))
        lipNode.renderingOrder = 12
        wrap.addChildNode(lipNode)
        parts.append(wrap)

        let cdNode = AlbumNode(albumID: album.id, format: .cd, signature: signature, parts: parts,
                               discPivot: extras ? makeDisc(album) : nil, reels: [])
        cdNode.wrapNode = wrap
        if !extras, let coverImage {
            let key: String = "reflect|" + signature
            if let img = cached(key, { Self.reflectionImage(coverImage, frame: nil, inset: 0) }) {
                cdNode.reflection = ReflectionFace(image: img, x: Float(W / 2 - 0.62), width: 1.2, height: 1.2, z: Float(D / 2))
            }
        }
        return cdNode
    }

    /// Le CD lui-même, rangé (invisible) dans le boîtier : un vrai disque de 120 mm,
    /// troué au centre, avec la face imprimée d'un côté et la face miroir irisée de l'autre.
    func makeDisc(_ album: AlbumInfo) -> SCNNode {
        if VinylCatalog.isVinyl(album.id) { return makeVinylDisc(album) }
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
    static func discGeometry(outer r1: Float, inner r0: Float, thickness: Float, faces: DiscFaces = .all, segments n: Int = 256) -> SCNGeometry {
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
        let size: CGFloat = 1800
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

    /// Calque transparent avec les stickers de l'album, posé sur la jaquette (en haut à droite).
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

    /// Stickers placés où tu les as mis, sur toute la surface de la jaquette.
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

    func renderTransparent<V: View>(_ view: V, _ size: CGSize) -> UIImage? {
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
        let size: CGFloat = 1800
        let R = size / 2
        let px = size / 1024
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
            let font = UIFont.monospacedSystemFont(ofSize: 15 * px, weight: .medium)
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
                str.draw(at: CGPoint(x: -w / 2, y: -radius - 8 * px), withAttributes: attrs)
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
        let corner: CGFloat = 0.035   // coins arrondis de 3,5 mm, comme les vrais boîtiers
        let insert = Physical.insert
        let platform = library.platform(of: game)

        // Plastique translucide : transparent (PS3), bleu foncé (PS4) ou bleu vif (PS5).
        let plastic = SCNMaterial()
        plastic.lightingModel = .physicallyBased
        plastic.diffuse.contents = platform.plastic
        plastic.roughness.contents = 0.26
        plastic.metalness.contents = 0.0
        plastic.clearCoat.contents = 0.7
        plastic.clearCoatRoughness.contents = 0.12
        plastic.blendMode = .alpha

        // Les images : les tiennes si tu en as choisi, sinon celles générées par Platine.
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

        // Un seul bloc : seules les arêtes extérieures sont arrondies, les pièces se touchent sans jour.
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
        // Fine rainure de fermeture entre le plateau et le couvercle.
        let seam = Self.roundedFrame(width: W + 0.002, height: H + 0.002, corner: corner, wall: 0.004, depth: 0.0016, chamfer: 0)
        let seamMat = SCNMaterial()
        seamMat.lightingModel = .constant
        seamMat.diffuse.contents = platform.plasticDark
        seam.materials = [seamMat]
        let seamNode = SCNNode(geometry: seam)
        seamNode.position.z = -0.004
        parts.append(seamNode)
        // Plateau intérieur (vu quand le boîtier est ouvert).
        let tray = SCNPlane(width: W - 0.07, height: H - 0.07)
        tray.cornerRadius = corner - 0.03
        tray.materials = [Self.printed(trayImage ?? UIColor.lightGray)]
        let trayNode = SCNNode(geometry: tray)
        trayNode.position.z = -0.0305
        parts.append(trayNode)
        // Charnière : la tige arrondie le long du dos, visible boîtier ouvert.
        let hinge = SCNCylinder(radius: 0.011, height: H - 0.16)
        hinge.materials = [plastic]
        let hingeNode = SCNNode(geometry: hinge)
        hingeNode.position = SCNVector3(Float(-W / 2) + 0.012, 0, -0.004)
        parts.append(hingeNode)
        // Dos imprimé, sous le film arrière.
        let backPrint = SCNPlane(width: insert.width, height: insert.height)
        backPrint.cornerRadius = 0.02
        backPrint.materials = [Self.printed(back ?? UIColor.darkGray)]
        let backPrintNode = SCNNode(geometry: backPrint)
        backPrintNode.eulerAngles.y = .pi
        backPrintNode.position.z = -0.0715
        parts.append(backPrintNode)
        parts.append(Self.filmNode(width: W - 0.03, height: H - 0.03, z: -0.0722, flipped: true, platinum: false))

        // Tranche droite (côté ouverture) : l'encoche pour le pouce et les deux petits ergots.
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
        // Tranche gauche : la jaquette en papier qui s'enroule, sous un film brillant.
        // Tranche de 14 mm × 148 mm : exactement la bande du milieu d'une vraie jaquette.
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

        // Couvercle : il tourne autour de la charnière, à gauche, comme un livre.
        let lidPivot = SCNNode()
        lidPivot.position = SCNVector3(Float(-W / 2), 0, -0.004)
        let lid = Self.roundedSlab(width: W, height: H, corner: corner, depth: 0.074, chamfer: 0.007, mode: .front)
        lid.materials = [plastic]
        let lidNode = SCNNode(geometry: lid)
        lidNode.position = SCNVector3(Float(W / 2), 0, 0.037)
        lidPivot.addChildNode(lidNode)
        // Rebord moulé en relief autour de la jaquette.
        let lip = Self.roundedFrame(width: W - 0.012, height: H - 0.012, corner: corner - 0.006, wall: 0.016, depth: 0.004, chamfer: 0.0015)
        lip.materials = [plastic]
        let lipNode = SCNNode(geometry: lip)
        lipNode.position = SCNVector3(Float(W / 2), 0, 0.0755)
        lidPivot.addChildNode(lipNode)
        // Petits creux moulés aux quatre coins.
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
        // La jaquette glissée sous le film transparent.
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
        // Intérieur du couvercle : la notice (visible boîtier ouvert).
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

    /// Reflet façon Cover Flow : l'image retournée, qui s'efface en descendant. Calculé une seule fois.
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
            // Retourné de haut en bas, comme dans un sol brillant.
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
            // Fondu : bien visible au pied de l'objet, invisible à mi-hauteur.
            let colors = [UIColor(white: 0, alpha: 0.30).cgColor, UIColor(white: 0, alpha: 0.10).cgColor, UIColor(white: 0, alpha: 0).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.28, 0.62]) {
                cg.setBlendMode(.destinationIn)
                cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: h), options: [.drawsAfterEndLocation])
            }
        }
    }

    /// Film plastique : reflets sur toute la surface, et un bord un peu plus brillant (surépaisseur).
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

    /// Bord du film plastique : liseré lumineux très fin, et reflet doux dans un coin.
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

    /// Plaque aux coins arrondis et aux arêtes adoucies, centrée (épaisseur sur z).
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

    /// Cadre aux coins arrondis (les parois du plateau), avec un trou au milieu.
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

    /// Jaquette générée (en attendant ta photo) : bandeau blanc, stade de nuit, pelouse et nom du jeu.
    static func generatedGameCover(title: String, season: String, count: Int, platform: GamePlatform = .ps5) -> UIImage {
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

            // Bandeau du haut aux couleurs de la console (noir PS3, bleu PS4, blanc PS5).
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

    /// Dos du boîtier comme sur les vrais jeux : papier blanc, bandeau en haut, titre en grand, référence en bas.
    static func gameSpine(title: String, platform: GamePlatform = .ps5) -> UIImage {
        let w: CGFloat = 136, h: CGFloat = 1650
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(white: 0.97, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            // Bandeau du haut aux couleurs de la console, séparé par un fin trait.
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
            // Titre du jeu, en très gros et penché, qui se lit de haut en bas.
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
            // Référence en bas, à l'horizontale, comme sur les vrais boîtiers.
            let ref = NSAttributedString(string: "PLAT\n0024", attributes: [
                .font: UIFont.systemFont(ofSize: 26, weight: .medium),
                .foregroundColor: UIColor(white: 0.15, alpha: 1)
            ])
            ref.draw(in: CGRect(x: 18, y: h - 120, width: w - 20, height: 80))
        }
    }

    /// Intérieur du couvercle : plastique bleu translucide, la notice en papier glissée dessous
    /// (texte en petits paragraphes), les deux clips qui la tiennent.
    static func gameBooklet(title: String, tracks: [(String, String)], platform: GamePlatform = .ps5) -> UIImage {
        let w: CGFloat = 1080, h: CGFloat = 1360
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(platform.trayDark.cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            // Bord du couvercle.
            c.setStrokeColor(platform.trayEdge.cgColor)
            c.setLineWidth(18)
            c.stroke(CGRect(x: 9, y: 9, width: w - 18, height: h - 18))
            // La notice, vue à travers le plastique (teinte bleutée).
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
            // Paragraphes de texte fin pour remplir la notice, comme sur la vraie.
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
            // Les deux clips transparents à gauche.
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

    /// Plateau intérieur comme sur un vrai boîtier PS5 : plastique bleu translucide,
    /// anneau en relief pour le disque, ergot central à branches, fines nervures en haut et en bas.
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
            // Bord épais du plateau.
            c.setStrokeColor(platform.trayEdge.cgColor)
            c.setLineWidth(26)
            c.stroke(CGRect(x: 13, y: 13, width: w - 26, height: h - 26))
            c.setStrokeColor(UIColor(white: 1, alpha: 0.5).cgColor)
            c.setLineWidth(3)
            c.stroke(CGRect(x: 34, y: 34, width: w - 68, height: h - 68))
            // Nervures en haut et en bas.
            c.setStrokeColor(UIColor(white: 1, alpha: 0.75).cgColor)
            c.setLineWidth(4)
            c.strokeLineSegments(between: [CGPoint(x: 110, y: 90), CGPoint(x: w - 110, y: 90),
                                           CGPoint(x: 110, y: h - 90), CGPoint(x: w - 110, y: h - 90)])
            // Anneau en relief autour du disque : ombre, puis reflet.
            let center = CGPoint(x: w / 2, y: h / 2)
            let r: CGFloat = 368
            c.setStrokeColor(UIColor(red: 0.2, green: 0.38, blue: 0.9, alpha: 0.9).cgColor)
            c.setLineWidth(16)
            c.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            c.setStrokeColor(UIColor(white: 1, alpha: 0.55).cgColor)
            c.setLineWidth(4)
            c.strokeEllipse(in: CGRect(x: center.x - r + 12, y: center.y - r + 12, width: 2 * r - 24, height: 2 * r - 24))
            // Encoches pour prendre le disque, à gauche et à droite.
            c.setFillColor(UIColor(red: 0.36, green: 0.52, blue: 0.95, alpha: 1).cgColor)
            for dx in [-r - 6, r - 40] {
                c.fill(CGRect(x: center.x + dx, y: center.y - 90, width: 46, height: 180))
            }
            // Ergot central : disque clair et branches en étoile.
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

    /// Face imprimée du disque de jeu : visuel en haut, bandeau blanc en bas, nom du jeu.
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
            // Bandeau blanc sur le bas du disque (dans la zone imprimée seulement).
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

        if let stickers = stickerLayer(album, badges: [], signature: signature, onlyCustom: true) {
            stickers.position = SCNVector3(0.28, -0.06, Float(D / 2) + 0.0015)
            stickers.scale = SCNVector3(0.62, 0.62, 0.62)
            parts.append(stickers)
        }

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

    func render<V: View>(_ view: V, _ size: CGSize, scale: CGFloat = 1.6) -> UIImage? {
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
        c.countLimit = 140
        // Limite en mémoire (les faces en haute définition sont lourdes).
        c.totalCostLimit = 320 * 1024 * 1024
        return c
    }()

    func cached(_ key: String, _ make: () -> UIImage?) -> UIImage? {
        if let img = Self.textures.object(forKey: key as NSString) { return img }
        guard let img = make() else { return nil }
        let cost = img.cgImage.map { $0.bytesPerRow * $0.height } ?? 1
        Self.textures.setObject(img, forKey: key as NSString, cost: cost)
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
    // MARK: Blister (film plastique d'un CD neuf)

    /// Film brillant : il n'ajoute que des reflets (le relief des plis vient d'une carte de relief).
    static func shrinkFilm(_ textures: (haze: UIImage, normal: UIImage)) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = textures.haze
        m.normal.contents = textures.normal
        m.normal.intensity = 1
        m.roughness.contents = 0.06
        m.metalness.contents = 0.0
        m.clearCoat.contents = 1.0
        m.clearCoatRoughness.contents = 0.03
        m.clearCoatNormal.contents = textures.normal
        m.blendMode = .add
        m.writesToDepthBuffer = false
        return m
    }

    static let shrinkFront = filmTextures(width: 512, height: 450, corners: true, seams: false, seed: 11)
    static let shrinkBack = filmTextures(width: 512, height: 450, corners: true, seams: true, seed: 23)
    static let shrinkSide = filmTextures(width: 256, height: 64, corners: false, seams: false, seed: 5)

    /// Fabrique le voile et le relief du film : tendu au centre (légères ondulations), froissé près des bords,
    /// plis en éventail dans les coins, et soudures au dos.
    static func filmTextures(width w: Int, height h: Int, corners: Bool, seams: Bool, seed: UInt64) -> (haze: UIImage, normal: UIImage) {
        var rng = SeededRandom(seed: seed)
        // Bruit lisse (grille aléatoire interpolée), sur plusieurs échelles.
        let grid = 33
        var lattice = [Double](repeating: 0, count: grid * grid)
        for i in lattice.indices { lattice[i] = rng.next(-1, 1) }
        func noise(_ x: Double, _ y: Double) -> Double {
            let fx = (x.truncatingRemainder(dividingBy: Double(grid - 1)) + Double(grid - 1)).truncatingRemainder(dividingBy: Double(grid - 1))
            let fy = (y.truncatingRemainder(dividingBy: Double(grid - 1)) + Double(grid - 1)).truncatingRemainder(dividingBy: Double(grid - 1))
            let x0 = Int(fx), y0 = Int(fy)
            let tx = fx - Double(x0), ty = fy - Double(y0)
            let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
            func at(_ a: Int, _ b: Int) -> Double { lattice[(b % grid) * grid + (a % grid)] }
            let top = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * sx
            let bottom = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * sx
            return top + (bottom - top) * sy
        }
        var height = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let u = Double(x) / Double(w - 1), v = Double(y) / Double(h - 1)
                let edge = min(u, 1 - u, v, 1 - v)
                let nearEdge = exp(-edge / 0.07)
                var value = 0.18 * noise(u * 3, v * 3)                        // le film n'est jamais parfaitement plat
                value += nearEdge * (0.55 * noise(u * 14, v * 14) + 0.3 * noise(u * 30, v * 30)) // froissé au bord
                if corners {
                    for (cx, cy) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
                        let dx = u - cx, dy = v - cy
                        let d = (dx * dx + dy * dy).squareRoot()
                        let fan = exp(-d / 0.09)
                        value += fan * 0.7 * sin(atan2(dy, dx) * 26 + noise(u * 8, v * 8) * 3)
                    }
                }
                if seams {
                    // Soudure horizontale au tiers, et pliage en enveloppe vers les coins.
                    value += 0.9 * exp(-abs(v - 0.34) / 0.006)
                    value += 0.5 * exp(-abs(abs(u - 0.5) * 2 - v * 0.6 - 0.4) / 0.01) * (v < 0.34 ? 1 : 0)
                }
                height[y * w + x] = value
            }
        }
        var normalBytes = [UInt8](repeating: 255, count: w * h * 4)
        var hazeBytes = [UInt8](repeating: 255, count: w * h * 4)
        let strength = 2.2
        for y in 0..<h {
            for x in 0..<w {
                let l = height[y * w + max(0, x - 1)], r = height[y * w + min(w - 1, x + 1)]
                let t = height[max(0, y - 1) * w + x], b = height[min(h - 1, y + 1) * w + x]
                var nx = (l - r) * strength, ny = (t - b) * strength, nz = 1.0
                let len = (nx * nx + ny * ny + nz * nz).squareRoot()
                nx /= len; ny /= len; nz /= len
                let o = (y * w + x) * 4
                normalBytes[o] = UInt8((nx * 0.5 + 0.5) * 255)
                normalBytes[o + 1] = UInt8((ny * 0.5 + 0.5) * 255)
                normalBytes[o + 2] = UInt8((nz * 0.5 + 0.5) * 255)
                // Voile laiteux très léger, plus marqué dans les plis (le film y est plus épais).
                let crease = min(1, abs(l - r) * 3 + abs(t - b) * 3)
                let haze = UInt8(min(255, 6 + crease * 34))
                hazeBytes[o] = haze; hazeBytes[o + 1] = haze; hazeBytes[o + 2] = haze
            }
        }
        func image(_ bytes: [UInt8]) -> UIImage {
            let data = Data(bytes) as CFData
            guard let provider = CGDataProvider(data: data),
                  let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                return UIImage()
            }
            return UIImage(cgImage: cg)
        }
        return (image(hazeBytes), image(normalBytes))
    }

    /// La bande de sécurité blanche collée sur le dessus des CD neufs.
    static func securityStrip(_ title: String) -> UIImage {
        let size = CGSize(width: 460, height: 100)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(white: 0.96, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .heavy),
                .foregroundColor: UIColor(white: 0.12, alpha: 1)
            ]
            (title.uppercased() as NSString).draw(in: CGRect(x: 14, y: 14, width: 300, height: 30), withAttributes: attrs)
            let small: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: UIColor(white: 0.35, alpha: 1)
            ]
            ("DISQUE COMPACT · NEUF · PLATINE" as NSString).draw(at: CGPoint(x: 14, y: 52), withAttributes: small)
            // Petit code-barres.
            var rng = SeededRandom(seed: UInt64(abs(title.hashValue % 9999)) + 1)
            var x: CGFloat = 330
            while x < 446 {
                let barW = CGFloat(rng.next(1, 4))
                UIColor(white: 0.1, alpha: 1).setFill()
                ctx.fill(CGRect(x: x, y: 18, width: barW, height: 62))
                x += barW + CGFloat(rng.next(1, 4))
            }
        }
    }

    /// Bulles, poussières et fines rayures du plastique d'un boîtier CD (dessiné une seule fois).
    static let plasticWear: UIImage = {
        let size = CGSize(width: 1024, height: 900)
        var rng = SeededRandom(seed: 42)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            UIColor.black.setFill()
            c.fill(CGRect(origin: .zero, size: size))
            // Voile laiteux très léger, plus marqué vers les bords.
            let colors = [UIColor(white: 1, alpha: 0).cgColor, UIColor(white: 1, alpha: 0.05).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.55, 1]) {
                c.drawRadialGradient(g, startCenter: CGPoint(x: size.width / 2, y: size.height / 2), startRadius: 0,
                                     endCenter: CGPoint(x: size.width / 2, y: size.height / 2), endRadius: size.width * 0.72, options: [])
            }
            // Bulles : petits cercles avec un reflet.
            for _ in 0..<70 {
                let r = CGFloat(rng.next(1.2, 4.5))
                let p = CGPoint(x: CGFloat(rng.next(0, Double(size.width))), y: CGFloat(rng.next(0, Double(size.height))))
                c.setStrokeColor(UIColor(white: 1, alpha: CGFloat(rng.next(0.12, 0.3))).cgColor)
                c.setLineWidth(0.8)
                c.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                c.setFillColor(UIColor(white: 1, alpha: 0.35).cgColor)
                c.fillEllipse(in: CGRect(x: p.x - r * 0.45, y: p.y - r * 0.55, width: r * 0.5, height: r * 0.5))
            }
            // Poussières.
            for _ in 0..<220 {
                let r = CGFloat(rng.next(0.4, 1.1))
                c.setFillColor(UIColor(white: 1, alpha: CGFloat(rng.next(0.05, 0.18))).cgColor)
                c.fillEllipse(in: CGRect(x: CGFloat(rng.next(0, Double(size.width))), y: CGFloat(rng.next(0, Double(size.height))),
                                         width: r * 2, height: r * 2))
            }
            // Micro-rayures fines, presque toutes dans le même sens (comme un boîtier manipulé).
            for _ in 0..<26 {
                let x = CGFloat(rng.next(0, Double(size.width))), y = CGFloat(rng.next(0, Double(size.height)))
                let length = CGFloat(rng.next(20, 140))
                let angle = CGFloat(rng.next(-0.5, 0.5)) + .pi / 5
                c.setStrokeColor(UIColor(white: 1, alpha: CGFloat(rng.next(0.04, 0.12))).cgColor)
                c.setLineWidth(CGFloat(rng.next(0.4, 0.9)))
                c.move(to: CGPoint(x: x, y: y))
                c.addLine(to: CGPoint(x: x + cos(angle) * length, y: y + sin(angle) * length))
                c.strokePath()
            }
        }
    }()

    /// Grain de surface : rend les bords du plastique un peu rugueux sous la lumière.
    static let plasticGrain: UIImage = {
        let size = CGSize(width: 128, height: 128)
        var rng = SeededRandom(seed: 7)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            for y in stride(from: 0, to: Int(size.height), by: 2) {
                for x in stride(from: 0, to: Int(size.width), by: 2) {
                    UIColor(white: CGFloat(rng.next(0.3, 0.55)), alpha: 1).setFill()
                    ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
                }
            }
        }
    }()

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
    @Environment(Library.self) private var library

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                // Ta pochette avant si tu en as choisi une (dans la Collection seulement), sinon celle du son.
                if let front = library.extraImage("front", album.id) {
                    Image(uiImage: front).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    ArtworkView(track: album.cover, animated: false, cornerRadius: 0)
                }
                if badges.contains(.platinum) { HoloSheen(light: -0.2) }
                PlacedStickers(album: album, badges: badges, size: geo.size)
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

            // Pas de sol 3D : le reflet de chaque objet est une image préparée à l'avance (bien plus léger).
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


// MARK: - Couleurs des boîtiers selon la console

extension GamePlatform {
    /// Plastique du boîtier : transparent (PS3), bleu foncé (PS4), bleu vif (PS5).
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
    /// Plateau intérieur : clair, puis plus sombre, et son bord.
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
    /// Bandeau du haut de la jaquette : noir (PS3), bleu (PS4), blanc (PS5).
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


/// Petit générateur de hasard reproductible (les textures sont identiques à chaque lancement).
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next(_ low: Double, _ high: Double) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Double(state >> 11) / Double(1 << 53)
        return low + (high - low) * unit
    }
}

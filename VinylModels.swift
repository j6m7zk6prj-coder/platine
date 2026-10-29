import SwiftUI
import SceneKit
import UIKit

// MARK: - Les pièces d'un vinyle

/// Ce qu'un vinyle a en plus d'un CD : sous-pochette, gatefold, double disque.
@MainActor
final class VinylRig {
    var stage: VinylStage = .jacket
    var gatefoldOpen = false
    /// Face visible sur le dessus du disque (A ou B ; C ou D pour le 2e disque).
    var sideB = false
    /// 0 = premier disque, 1 = deuxième (double vinyle).
    var discIndex = 0
    var discs = 1
    /// Volet avant du gatefold, qui s'ouvre comme un livre.
    var lidPivot: SCNNode?
    /// Les deux faces de chaque disque (dessinées au besoin).
    var faces: @MainActor (Int) -> (front: UIImage?, back: UIImage?) = { _ in (nil, nil) }
    // Pièces du disque, retrouvées une fois.
    var sleeve: SCNNode?
    var holder: SCNNode?
    var mesh: SCNNode?
    /// Change à chaque nouvelle étape : une ancienne animation ne termine jamais par-dessus la nouvelle.
    var token = 0
}

@MainActor
extension AlbumNode {
    /// Sous-pochette, disque et sa « main » (le nœud qui le déplace), retrouvés dans le disque fabriqué.
    private func vinylParts() -> (sleeve: SCNNode, holder: SCNNode, mesh: SCNNode)? {
        guard let rig = vinyl else { return nil }
        if let s = rig.sleeve, let h = rig.holder, let m = rig.mesh { return (s, h, m) }
        guard let pivot = discPivot,
              let s = pivot.childNode(withName: "sleeve", recursively: false),
              let h = pivot.childNode(withName: "discHolder", recursively: false),
              let m = h.childNode(withName: "discMesh", recursively: true) else { return nil }
        rig.sleeve = s
        rig.holder = h
        rig.mesh = m
        return (s, h, m)
    }


    /// Ouvre ou referme le gatefold (la pochette s'ouvre en deux comme un livre).
    func setGatefold(open: Bool, animated: Bool = true) {
        guard let rig = vinyl, let lid = rig.lidPivot, rig.stage == .jacket, open != rig.gatefoldOpen else { return }
        rig.gatefoldOpen = open
        let s: Float = fit * 0.55
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.8 : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.8, 0.25, 1)
        lid.eulerAngles = open ? SCNVector3(0, -Float.pi, 0) : SCNVector3(0, 0, 0)
        content.scale = open ? SCNVector3(s, s, s) : SCNVector3(fit, fit, fit)
        content.position = open ? SCNVector3(size.x / 2 * s, 0, 0) : SCNVector3(0, 0, 0)
        SCNTransaction.commit()
    }

    /// Les deux étapes du vinyle : dans sa pochette, ou sorti (à moitié dans sa sous-pochette).
    func setVinylStage(_ target: VinylStage, animated: Bool = true) {
        guard let rig = vinyl, target != rig.stage, let parts = vinylParts(), let pivot = discPivot else { return }
        let from = rig.stage
        rig.stage = target
        rig.token += 1
        let token = rig.token
        if rig.gatefoldOpen, let lid = rig.lidPivot {
            rig.gatefoldOpen = false
            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.5 : 0
            lid.eulerAngles = SCNVector3(0, 0, 0)
            SCNTransaction.commit()
        }
        let speed: Double = animated ? 1 : 0

        switch (from, target) {
        case (.jacket, .out):
            // 1. La sous-pochette glisse hors de la pochette. 2. Le disque sort à moitié de la sous-pochette.
            pivot.opacity = 1
            parts.sleeve.opacity = 1
            transaction(0.6 * speed, curve: (0.25, 0.9, 0.3, 1)) {
                self.poseOut(pivot: pivot, holderUp: false)
            } done: {
                guard rig.token == token else { return }
                self.transaction(0.55 * speed, curve: (0.3, 0.85, 0.3, 1)) {
                    parts.holder.position = SCNVector3(0, 1.0, 0.0)
                }
            }

        case (.out, .jacket):
            transaction(0.4 * speed, curve: (0.4, 0, 0.2, 1)) {
                parts.holder.position = SCNVector3(0, 0, 0)
            } done: {
                guard rig.token == token else { return }
                self.transaction(0.5 * speed, curve: (0.4, 0, 0.2, 1)) {
                    self.poseJacket(pivot: pivot)
                } done: {
                    if rig.token == token { pivot.opacity = 0 }
                }
            }

        default:
            break
        }
    }

    private func poseOut(pivot: SCNNode, holderUp: Bool) {
        let s: Float = fit * 0.63
        content.scale = SCNVector3(s, s, s)
        content.position = SCNVector3(-0.1 * s, -0.5 * s, 0)
        body.position = SCNVector3(-1.2, 0, 0)
        body.opacity = 1
        pivot.position = SCNVector3(1.4, 0, 0.012)
        if holderUp { vinyl?.holder?.position = SCNVector3(0, 1.0, 0) }
    }

    private func poseJacket(pivot: SCNNode) {
        content.scale = SCNVector3(fit, fit, fit)
        content.position = SCNVector3(0, 0, 0)
        body.position = SCNVector3(0, 0, 0)
        body.opacity = 1
        pivot.position = SCNVector3(0, 0, 0)
    }

    private func transaction(_ duration: Double, curve: (Float, Float, Float, Float),
                             _ changes: () -> Void, done: (() -> Void)? = nil) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints: curve.0, curve.1, curve.2, curve.3)
        if let done { SCNTransaction.completionBlock = { Task { @MainActor in done() } } }
        changes()
        SCNTransaction.commit()
    }

    /// Remet le vinyle dans sa pochette, sans animation.
    func settleVinyl() {
        guard let rig = vinyl else { return }
        rig.token += 1
        rig.stage = .jacket
        rig.gatefoldOpen = false
        rig.lidPivot?.eulerAngles = SCNVector3(0, 0, 0)
        if let parts = vinylParts(), let pivot = discPivot {
            parts.holder.removeAllActions()
            if parts.holder.parent !== pivot {
                parts.holder.removeFromParentNode()
                pivot.addChildNode(parts.holder)
            }
            // Rangé : on repart toujours de la face A du premier disque.
            if rig.discIndex != 0, let m = parts.mesh.geometry?.materials, m.count >= 2 {
                let faces = rig.faces(0)
                m[0].diffuse.contents = faces.front
                m[1].diffuse.contents = faces.back
            }
            rig.sideB = false
            rig.discIndex = 0
            parts.holder.opacity = 1
            parts.holder.position = SCNVector3(0, 0, 0)
            parts.holder.eulerAngles = SCNVector3(0, 0, 0)
            parts.sleeve.opacity = 1
            pivot.position = SCNVector3(0, 0, 0)
            pivot.opacity = 0
        }
        body.position = SCNVector3(0, 0, 0)
        body.opacity = 1
    }

    /// Retourne le disque sorti pour voir l'autre face (A ↔ B) ; sur un double vinyle,
    /// la face suivante passe au 2e disque.
    func flipDisc(toSide side: Int) {
        guard let rig = vinyl, rig.stage == .out, let parts = vinylParts(),
              parts.holder.action(forKey: "flip") == nil else { return }
        let disc = min(rig.discs - 1, max(0, side / 2))
        let wantB = side % 2 == 1
        guard disc != rig.discIndex || wantB != rig.sideB else { return }
        let swap = disc != rig.discIndex
        rig.sideB = wantB
        rig.discIndex = disc
        let turn = SCNAction.rotateTo(x: 0, y: wantB ? CGFloat.pi : 0, z: 0, duration: 0.6, usesShortestUnitArc: true)
        turn.timingMode = .easeInEaseOut
        if swap {
            // Double vinyle : un disque part, l'autre arrive.
            let faces = rig.faces(disc)
            let front = faces.front, back = faces.back
            let mesh = parts.mesh
            parts.holder.runAction(.sequence([
                .fadeOut(duration: 0.2),
                .run { _ in
                    if let m = mesh.geometry?.materials, m.count >= 2 {
                        m[0].diffuse.contents = front
                        m[1].diffuse.contents = back
                    }
                },
                turn,
                .fadeIn(duration: 0.25)
            ]), forKey: "flip")
        } else {
            parts.holder.runAction(turn, forKey: "flip")
        }
    }
}

// MARK: - Fabrication du vinyle

extension AlbumNodeBuilder {
    func makeVinyl(_ album: AlbumInfo, badges: [AlbumBadge], signature: String) -> AlbumNode {
        let options = library.vinylOptions(album.id)
        let discs = VinylLayout.discCount(album, options)
        let W: CGFloat = 3.15, H: CGFloat = 3.15
        let D: CGFloat = options.gatefold ? 0.044 : (discs > 1 ? 0.05 : 0.034)
        let palette = library.palette(for: album.cover)
        let edgeColor = UIColor(palette[0])
        let wear = settings.ringWear ? library.ringWear(album) : 0
        let seed = PriceTag.stableHash(album.id)
        let code = EAN13(seed: album.id)
        let catalog = "PLT-LP " + code.digits.dropFirst(7).prefix(5).map(String.init).joined()
        var parts: [SCNNode] = []

        // Recto, verso et tranche : impression sur carton, coins légèrement usés, cercle du disque marqué à force d'écoute.
        let front = cached("lpfront|" + signature) {
            guard let base = render(CoverFace(album: album, badges: badges), CGSize(width: 640, height: 640), scale: hiRes ? 3.2 : 1.6) else { return nil }
            return VinylTextures.agedPrint(base, ring: wear, seed: seed, edge: 1, size: hiRes ? 2048 : 1024)
        }
        let back = cached("lpback|" + signature) {
            guard let base = render(VinylBackInsert(album: album, discs: discs, catalog: catalog),
                                    CGSize(width: 640, height: 640), scale: hiRes ? 3.2 : 1.6) else { return nil }
            return VinylTextures.agedPrint(base, ring: wear * 0.8, seed: seed &+ 7, edge: 0.8, size: hiRes ? 2048 : 1024)
        }
        let spine = cached("lpspine|" + signature) {
            VinylTextures.spine(title: album.title, artist: album.artist, catalog: catalog, color: edgeColor)
        }
        let frontMat = Self.printed(front ?? UIColor.darkGray)
        let backMat = Self.printed(back ?? UIColor.darkGray)
        let spineMat = Self.printed(spine ?? edgeColor)
        let edgeMat = Self.printed(VinylTextures.edge(edgeColor, opening: false))
        let openMat = Self.printed(VinylTextures.edge(edgeColor, opening: true))
        let glossStrength: CGFloat = options.finish == .glossy ? 0.55 : 0.14

        let rig = VinylRig()
        rig.discs = discs

        if options.gatefold {
            // Gatefold : deux volets ; l'intérieur s'ouvre sur une double page (la tienne ou celle de Platine).
            let spread = library.extraImage("inner", album.id) ?? cached("lpinner|" + signature) {
                VinylTextures.innerSpread(album: album, sides: VinylLayout.sides(album, discs: discs),
                                          cover: library.image(for: album.cover), catalog: catalog)
            }
            let left = spread.map { CaseCustomizer.slice($0, 0, 0.5) }
            let right = spread.map { CaseCustomizer.slice($0, 0.5, 1) }
            let half = D / 2
            let backPanel = SCNBox(width: W, height: H, length: half, chamferRadius: 0.005)
            backPanel.materials = [Self.printed(right ?? UIColor.darkGray), openMat, backMat, spineMat, edgeMat, edgeMat]
            let backNode = SCNNode(geometry: backPanel)
            backNode.position.z = Float(-half / 2)
            parts.append(backNode)

            let lid = SCNNode()
            lid.position = SCNVector3(Float(-W / 2), 0, 0)
            let frontPanel = SCNBox(width: W, height: H, length: half, chamferRadius: 0.005)
            frontPanel.materials = [frontMat, edgeMat, Self.printed(left ?? UIColor.darkGray), spineMat, edgeMat, edgeMat]
            let frontNode = SCNNode(geometry: frontPanel)
            frontNode.position = SCNVector3(Float(W / 2), 0, Float(half / 2))
            lid.addChildNode(frontNode)
            let gloss = SCNNode(geometry: SCNPlane(width: W - 0.01, height: H - 0.01))
            gloss.geometry?.materials = [Self.glassy(strength: glossStrength)]
            gloss.position = SCNVector3(Float(W / 2), 0, Float(half) + 0.0012)
            gloss.renderingOrder = 11
            lid.addChildNode(gloss)
            parts.append(lid)
            rig.lidPivot = lid
        } else {
            let jacket = SCNBox(width: W, height: H, length: D, chamferRadius: 0.006)
            jacket.materials = [frontMat, openMat, backMat, spineMat, edgeMat, edgeMat]
            parts.append(SCNNode(geometry: jacket))
            let gloss = SCNNode(geometry: SCNPlane(width: W - 0.01, height: H - 0.01))
            gloss.geometry?.materials = [Self.glassy(strength: glossStrength)]
            gloss.position.z = Float(D / 2) + 0.0012
            gloss.renderingOrder = 11
            parts.append(gloss)
        }

        // Étiquette prix du disquaire, en haut à gauche.
        if settings.priceStickers {
            // Étiquette d'étiqueteuse (un peu plus grande sur les vinyles : 30 × 18 mm).
            let tag = Self.priceTagNode(library.priceLabel(for: album, discs: discs), width: 0.3)
            tag.position = SCNVector3(Float(-W / 2 + 0.32), Float(H / 2 - 0.2), Float(D / 2) + 0.0085)
            tag.eulerAngles.z = 0.03
            parts.append(tag)
        }

        // Blister : film plastique tendu, avec le sticker rond « Inclut… ».
        let wrap = SCNNode()
        let film = SCNBox(width: W + 0.012, height: H + 0.012, length: D + 0.012, chamferRadius: 0.008)
        film.materials = [Self.shrinkFilm(Self.shrinkFront), Self.shrinkFilm(Self.shrinkSide),
                          Self.shrinkFilm(Self.shrinkBack), Self.shrinkFilm(Self.shrinkSide),
                          Self.shrinkFilm(Self.shrinkSide), Self.shrinkFilm(Self.shrinkSide)]
        let filmNode = SCNNode(geometry: film)
        filmNode.renderingOrder = 13
        wrap.addChildNode(filmNode)
        if options.hype {
            let favorite = album.tracks.max { $0.playCount < $1.playCount } ?? album.tracks.first
            let text = options.hypeText.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "hype|" + album.id + "|" + text + "|" + (favorite?.title ?? "")
            if let img = cached(key, { VinylTextures.hypeSticker(text: text, single: favorite?.title ?? album.title, discs: discs) }) {
                let plane = SCNPlane(width: 0.82, height: 0.82)
                let m = Self.printed(img)
                m.blendMode = .alpha
                m.writesToDepthBuffer = false
                plane.materials = [m]
                let n = SCNNode(geometry: plane)
                n.position = SCNVector3(Float(W / 2 - 0.62), Float(H / 2 - 0.62), Float(D / 2) + 0.0072)
                n.renderingOrder = 14
                wrap.addChildNode(n)
            }
        }
        parts.append(wrap)

        let node = AlbumNode(albumID: album.id, format: .vinyl, signature: signature, parts: parts, discPivot: nil, reels: [])
        node.wrapNode = wrap
        let builder = self
        let sides = VinylLayout.sides(album, discs: discs)
        rig.faces = { index in
            builder.vinylFaces(album, sides: sides, disc: index, options: options, catalog: catalog)
        }
        node.vinyl = rig
        return node
    }

    /// Les deux faces d'un disque (A/B ou C/D).
    func vinylFaces(_ album: AlbumInfo, sides: [VinylSide], disc: Int, options: VinylOptions, catalog: String)
        -> (front: UIImage?, back: UIImage?) {
        let label: UIImage? = library.extraImage("disc", album.id) ?? library.image(for: album.cover)
        let labelName: String = library.extraImageName("disc", album.id) ?? (library.artworkURL(album.cover)?.lastPathComponent ?? "-")
        var out: [UIImage?] = []
        for k in 0..<2 {
            let i = disc * 2 + k
            let side = sides.indices.contains(i) ? sides[i] : nil
            let letter = ["A", "B", "C", "D"][min(3, i)]
            let key = "lpface|" + album.id + "|" + letter + "|" + options.color.rawValue + "|" + labelName + "|" + String(album.tracks.count)
            out.append(cached(key) {
                VinylTextures.face(label: label, side: side, letter: letter, color: options.color,
                                   title: album.title, artist: album.artist, year: album.year,
                                   catalog: catalog, seed: PriceTag.stableHash(album.id) &+ UInt64(i))
            })
        }
        return (out[0], out[1])
    }

    /// Le disque dans sa sous-pochette, prêt à sortir.
    func makeVinylDisc(_ album: AlbumInfo) -> SCNNode {
        let options = library.vinylOptions(album.id)
        let discs = VinylLayout.discCount(album, options)
        let code = EAN13(seed: album.id)
        let catalog = "PLT-LP " + code.digits.dropFirst(7).prefix(5).map(String.init).joined()
        let faces = vinylFaces(album, sides: VinylLayout.sides(album, discs: discs), disc: 0, options: options, catalog: catalog)
        let translucent = options.color.isTranslucent

        func face(_ image: UIImage?) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = image
            m.blendMode = .alpha
            m.writesToDepthBuffer = !translucent
            m.isDoubleSided = false
            m.shaderModifiers = [.fragment: VinylTextures.sheen]
            return m
        }
        let c = options.color.base
        let rim = SCNMaterial()
        rim.lightingModel = .physicallyBased
        rim.diffuse.contents = UIColor(red: c.r, green: c.g, blue: c.b, alpha: max(0.5, c.a))
        rim.roughness.contents = 0.3
        let geometry = Self.discGeometry(outer: 1.5, inner: 0.036, thickness: 0.014, segments: 384)
        geometry.materials = [face(faces.front), face(faces.back), rim, rim]
        let mesh = SCNNode(geometry: geometry)
        mesh.name = "discMesh"
        let holder = SCNNode()
        holder.name = "discHolder"
        holder.addChildNode(mesh)

        // Sous-pochette : papier blanc troué au centre, ou plastique translucide.
        let paper = options.sleeve == .paper
        let sleeve = SCNBox(width: 3.06, height: 3.06, length: 0.026, chamferRadius: 0.004)
        let faceMat = SCNMaterial()
        faceMat.lightingModel = .physicallyBased
        faceMat.diffuse.contents = paper ? VinylTextures.paperSleeve : VinylTextures.plasticSleeve
        faceMat.roughness.contents = paper ? 0.85 : 0.12
        faceMat.blendMode = .alpha
        faceMat.writesToDepthBuffer = false
        if !paper {
            faceMat.clearCoat.contents = 0.8
            faceMat.clearCoatRoughness.contents = 0.05
        }
        let sideMat = SCNMaterial()
        sideMat.lightingModel = .physicallyBased
        sideMat.diffuse.contents = paper ? UIColor(white: 0.93, alpha: 1) : UIColor(white: 1, alpha: 0.25)
        sideMat.blendMode = .alpha
        sideMat.writesToDepthBuffer = false
        // Le haut de la sous-pochette est ouvert : le disque en sort.
        let openTop = SCNMaterial()
        openTop.diffuse.contents = UIColor.clear
        openTop.transparency = 0
        sleeve.materials = [faceMat, sideMat, faceMat, sideMat, openTop, sideMat]
        let sleeveNode = SCNNode(geometry: sleeve)
        sleeveNode.name = "sleeve"
        sleeveNode.renderingOrder = 8

        let pivot = SCNNode()
        pivot.addChildNode(holder)
        pivot.addChildNode(sleeveNode)
        pivot.opacity = 0
        return pivot
    }

    /// Étiquette prix collée, sortie de l'étiqueteuse du magasin.
    static func priceTagNode(_ label: PriceLabel, width: CGFloat) -> SCNNode {
        let key = "price3|" + label.key + "|" + label.reference
        let image: UIImage
        if let img = textures.object(forKey: key as NSString) { image = img } else {
            image = VinylTextures.priceSticker(label)
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

// MARK: - Le bac et l'étagère

@MainActor
enum VinylFurniture {
    /// Bac en bois de disquaire : les vinyles y sont rangés debout, on les feuillette du doigt.
    static func crate(innerWidth: CGFloat) -> SCNNode {
        let node = SCNNode()
        let t: CGFloat = 0.05, height: CGFloat = 0.64
        let front: CGFloat = 1.0, back: CGFloat = -1.3
        let depth = front - back
        let wood = SCNMaterial()
        wood.lightingModel = .physicallyBased
        wood.diffuse.contents = VinylTextures.wood(dark: false)
        wood.roughness.contents = 0.75
        let sides = SCNMaterial()
        sides.lightingModel = .physicallyBased
        sides.diffuse.contents = VinylTextures.crateSide
        sides.roughness.contents = 0.75
        func box(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ x: CGFloat, _ y: CGFloat, _ z: CGFloat, _ m: [SCNMaterial]) {
            let b = SCNBox(width: w, height: h, length: l, chamferRadius: 0.008)
            b.materials = m
            let n = SCNNode(geometry: b)
            n.position = SCNVector3(Float(x), Float(y), Float(z))
            node.addChildNode(n)
        }
        let outer = innerWidth + 2 * t
        box(outer, 0.06, depth + 2 * t, 0, 0.03, (front + back) / 2, [wood])
        box(outer, height, t, 0, height / 2, front + t / 2, [wood])
        box(outer, height, t, 0, height / 2, back - t / 2, [wood])
        for s in [-1.0, 1.0] {
            box(t, height, depth, CGFloat(s) * (innerWidth / 2 + t / 2), height / 2, (front + back) / 2, [wood, sides, wood, sides, wood, wood])
        }
        // Petite carte du disquaire sur l'avant du bac.
        let card = SCNPlane(width: 0.7, height: 0.2)
        let m = AlbumNodeBuilder.printed(VinylTextures.crateCard)
        card.materials = [m]
        let cardNode = SCNNode(geometry: card)
        cardNode.position = SCNVector3(0, Float(height * 0.55), Float(front + t) + 0.003)
        node.addChildNode(cardNode)
        return node
    }

    /// Étagère murale : une longue planche où les vinyles sont posés de face.
    static func ledge() -> SCNNode {
        let b = SCNBox(width: 60, height: 0.06, length: 0.36, chamferRadius: 0.01)
        let wood = SCNMaterial()
        wood.lightingModel = .physicallyBased
        wood.diffuse.contents = VinylTextures.wood(dark: true)
        wood.diffuse.contentsTransform = SCNMatrix4MakeScale(30, 1, 1)
        wood.diffuse.wrapS = .repeat
        wood.roughness.contents = 0.6
        b.materials = [wood]
        let n = SCNNode(geometry: b)
        n.position = SCNVector3(0, 0.03, 0)
        // Petit rebord devant, qui retient les pochettes.
        let lip = SCNBox(width: 60, height: 0.08, length: 0.03, chamferRadius: 0.008)
        lip.materials = [wood]
        let lipNode = SCNNode(geometry: lip)
        lipNode.position = SCNVector3(0, 0.07, 0.165)
        n.addChildNode(lipNode)
        return n
    }
}

// MARK: - Textures des vinyles

@MainActor
enum VinylTextures {
    /// Reflet du sillon : une traînée de lumière qui reste face à la lampe pendant que le disque tourne,
    /// avec une pointe d'arc-en-ciel, comme sur un vrai vinyle.
    static let sheen = """
    #pragma body
    float2 uv = _surface.diffuseTexcoord - float2(0.5, 0.5);
    float r = length(uv) * 2.0;
    float3 center = (scn_node.modelViewTransform * float4(0.0, 0.0, 0.0, 1.0)).xyz;
    float3 d = _surface.position - center;
    float a = atan2(d.y, d.x);
    float3 n = normalize(_surface.normal);
    float tilt = n.x * 2.2 + n.y * 1.6;
    float zone = smoothstep(0.34, 0.36, r) * (1.0 - smoothstep(0.975, 0.992, r));
    float c1 = abs(cos(a - 0.85 + tilt));
    float bow = pow(c1, 22.0);
    float glow = pow(c1, 3.0);
    float3 rainbow = 0.5 + 0.5 * cos(6.28318 * (a * 0.32 + r * 2.2 + float3(0.0, 0.33, 0.67)));
    float3 shine = float3(0.36 * bow + 0.05 * glow) + rainbow * 0.06 * bow;
    _output.color.rgb += shine * zone * _output.color.a;
    """

    private static func renderer(_ size: CGSize, opaque: Bool = false) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format)
    }

    /// Grain du carton (petite image répétée).
    static let grain: UIImage = {
        renderer(CGSize(width: 256, height: 256)).image { ctx in
            var rng = SeededRandom(seed: 41)
            for _ in 0..<2600 {
                let v = rng.next(0, 1)
                ctx.cgContext.setFillColor(UIColor(white: v > 0.5 ? 1 : 0, alpha: CGFloat(rng.next(0.02, 0.07))).cgColor)
                ctx.cgContext.fill(CGRect(x: rng.next(0, 256), y: rng.next(0, 256), width: rng.next(0.6, 2.2), height: rng.next(0.6, 1.4)))
            }
        }
    }()

    /// Impression sur carton : grain, coins et bords un peu usés, cercle du disque marqué (pochettes très écoutées).
    static func agedPrint(_ base: UIImage, ring: Double, seed: UInt64, edge: Double, size side: CGFloat = 1024) -> UIImage {
        let size = CGSize(width: side, height: side)
        // Les détails (usure, cercle) gardent la même taille réelle quelle que soit la définition.
        let k = Double(side / 1024)
        return renderer(size, opaque: true).image { ctx in
            let c = ctx.cgContext
            base.draw(in: CGRect(origin: .zero, size: size))
            // Grain du carton.
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    grain.draw(at: CGPoint(x: x, y: y))
                    x += 256
                }
                y += 256
            }
            var rng = SeededRandom(seed: seed)
            // Cercle du disque : le relief du vinyle finit par se voir à travers le carton.
            if ring > 0.05 {
                let center = CGPoint(x: size.width / 2 + CGFloat(rng.next(-6, 6)), y: size.height / 2 + CGFloat(rng.next(-4, 10)))
                let radius = size.width * 0.47
                c.saveGState()
                c.setBlendMode(.screen)
                c.setShadow(offset: .zero, blur: CGFloat(10 * k), color: UIColor(white: 1, alpha: CGFloat(0.35 * ring)).cgColor)
                c.setStrokeColor(UIColor(white: 1, alpha: CGFloat(0.09 * ring)).cgColor)
                c.setLineWidth(CGFloat(9 * k))
                c.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
                // Le relief du macaron central, plus discret.
                let small = size.width * 0.17
                c.setStrokeColor(UIColor(white: 1, alpha: CGFloat(0.05 * ring)).cgColor)
                c.setLineWidth(CGFloat(6 * k))
                c.strokeEllipse(in: CGRect(x: center.x - small, y: center.y - small, width: 2 * small, height: 2 * small))
                c.restoreGState()
            }
            // Bords et coins frottés (le carton blanc apparaît).
            let count = Int(260 * edge)
            for _ in 0..<count {
                let side = Int(rng.next(0, 4))
                let along = rng.next(0, 1)
                // Plus d'usure près des coins.
                let cornerBias = pow(abs(along - 0.5) * 2, 3)
                guard rng.next(0, 1) < 0.35 + 0.65 * cornerBias else { continue }
                let depth = rng.next(0.5, 4 + 9 * cornerBias) * k
                let len = rng.next(3, 18) * k
                let alpha = CGFloat(rng.next(0.15, 0.5))
                var rect: CGRect
                switch side {
                case 0: rect = CGRect(x: along * Double(size.width), y: 0, width: len, height: depth)
                case 1: rect = CGRect(x: along * Double(size.width), y: Double(size.height) - depth, width: len, height: depth)
                case 2: rect = CGRect(x: 0, y: along * Double(size.height), width: depth, height: len)
                default: rect = CGRect(x: Double(size.width) - depth, y: along * Double(size.height), width: depth, height: len)
                }
                c.setFillColor(UIColor(white: 0.93, alpha: alpha).cgColor)
                c.fill(rect)
            }
            // Coins arrondis par l'usure.
            for (cx, cy) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
                let p = CGPoint(x: cx * Double(size.width), y: cy * Double(size.height))
                c.setFillColor(UIColor(white: 0.9, alpha: CGFloat(rng.next(0.25, 0.5) * edge)).cgColor)
                let rr = CGFloat(9 * k)
                c.fillEllipse(in: CGRect(x: p.x - rr, y: p.y - rr, width: 2 * rr, height: 2 * rr))
            }
        }
    }

    /// Tranche de la pochette (3 à 5 mm) : artiste, titre et catalogue, lus de haut en bas.
    static func spine(title: String, artist: String, catalog: String, color: UIColor) -> UIImage {
        let w: CGFloat = 64, h: CGFloat = 5760
        return renderer(CGSize(width: w, height: h), opaque: true).image { ctx in
            let c = ctx.cgContext
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            c.setFillColor(UIColor(red: r * 0.5, green: g * 0.5, blue: b * 0.5, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let text = NSMutableAttributedString(string: artist.uppercased(), attributes: [
                .font: UIFont.systemFont(ofSize: 34, weight: .heavy), .foregroundColor: UIColor.white, .kern: 3
            ])
            text.append(NSAttributedString(string: "    " + title, attributes: [
                .font: UIFont.systemFont(ofSize: 34, weight: .medium), .foregroundColor: UIColor(white: 1, alpha: 0.8)
            ]))
            let cat = NSAttributedString(string: catalog, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 26, weight: .semibold), .foregroundColor: UIColor(white: 1, alpha: 0.7)
            ])
            c.saveGState()
            c.translateBy(x: w / 2, y: 0)
            c.rotate(by: .pi / 2)
            let tb = text.size()
            let shrink = min(1, (h - 900) / max(tb.width, 1))
            c.saveGState()
            c.translateBy(x: 160, y: 0)
            c.scaleBy(x: shrink, y: shrink)
            text.draw(at: CGPoint(x: 0, y: -tb.height / 2))
            c.restoreGState()
            let cb = cat.size()
            cat.draw(at: CGPoint(x: h - cb.width - 160, y: -cb.height / 2))
            c.restoreGState()
        }
    }

    /// Bords de la pochette (carton imprimé replié) ; côté ouverture : la fente sombre.
    static func edge(_ color: UIColor, opening: Bool) -> UIImage {
        let key = "lpedge|" + (opening ? "o" : "c") + "|" + color.description
        if let img = AlbumNodeBuilder.textures.object(forKey: key as NSString) { return img }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let img = renderer(CGSize(width: 32, height: 256), opaque: true).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(red: r * 0.6 + 0.1, green: g * 0.6 + 0.1, blue: b * 0.6 + 0.1, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: 32, height: 256))
            if opening {
                c.setFillColor(UIColor(white: 0.02, alpha: 1).cgColor)
                c.fill(CGRect(x: 9, y: 0, width: 14, height: 256))
                c.setFillColor(UIColor(white: 0.9, alpha: 1).cgColor)
                c.fill(CGRect(x: 12, y: 0, width: 2, height: 256))
            }
        }
        AlbumNodeBuilder.textures.setObject(img, forKey: key as NSString)
        return img
    }

    /// Sous-pochette en papier : blanc cassé, fibres, trou rond au centre pour voir l'étiquette.
    static let paperSleeve: UIImage = {
        let s: CGFloat = 2048
        return renderer(CGSize(width: s, height: s)).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(red: 0.95, green: 0.94, blue: 0.91, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: s, height: s))
            var rng = SeededRandom(seed: 17)
            for _ in 0..<3600 {
                c.setStrokeColor(UIColor(white: rng.next(0, 1) > 0.5 ? 1 : 0.6, alpha: CGFloat(rng.next(0.04, 0.12))).cgColor)
                c.setLineWidth(CGFloat(rng.next(0.5, 1.2)))
                let x = rng.next(0, Double(s)), y = rng.next(0, Double(s))
                c.strokeLineSegments(between: [CGPoint(x: x, y: y), CGPoint(x: x + rng.next(-12, 12), y: y + rng.next(-12, 12))])
            }
            // Plis légers.
            c.setFillColor(UIColor(white: 0, alpha: 0.035).cgColor)
            c.fill(CGRect(x: s * 0.62, y: 0, width: 3, height: s))
            c.fill(CGRect(x: 0, y: s * 0.27, width: s, height: 2))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 30, weight: .medium), .foregroundColor: UIColor(white: 0.55, alpha: 1), .kern: 4
            ]
            NSAttributedString(string: "PLATINE · À MANIPULER PAR LES BORDS", attributes: attrs).draw(at: CGPoint(x: 120, y: s - 140))
            // Le trou central (90 mm).
            c.setBlendMode(.clear)
            let hole = s * 0.146
            c.fillEllipse(in: CGRect(x: s / 2 - hole, y: s / 2 - hole, width: 2 * hole, height: 2 * hole))
        }
    }()

    /// Sous-pochette en plastique : voile laiteux translucide et quelques reflets.
    static let plasticSleeve: UIImage = {
        let s: CGFloat = 512
        return renderer(CGSize(width: s, height: s)).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(white: 1, alpha: 0.2).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: s, height: s))
            var rng = SeededRandom(seed: 29)
            for _ in 0..<40 {
                c.setFillColor(UIColor(white: 1, alpha: CGFloat(rng.next(0.03, 0.1))).cgColor)
                c.fill(CGRect(x: rng.next(0, Double(s)), y: 0, width: rng.next(2, 18), height: Double(s)))
            }
        }
    }()

    /// Une face du disque : matière (noir, couleur, marbré, éclaboussé, picture disc), sillons séparés
    /// entre chaque morceau, et l'étiquette centrale avec la pochette en rond, la face, l'année et la durée.
    static func face(label: UIImage?, side: VinylSide?, letter: String, color: VinylColor,
                     title: String, artist: String, year: Int, catalog: String, seed: UInt64) -> UIImage {
        let size: CGFloat = 2048
        let R = size / 2
        // Tailles prévues pour 1536 px : tout est mis à l'échelle (sillons plus fins et plus nombreux).
        let px = size / 1536
        return renderer(CGSize(width: size, height: size)).image { ctx in
            let c = ctx.cgContext
            let center = CGPoint(x: R, y: R)
            func circle(_ f: CGFloat) -> CGRect { CGRect(x: R - R * f, y: R - R * f, width: 2 * R * f, height: 2 * R * f) }
            let base = color.base
            let baseColor = UIColor(red: base.r, green: base.g, blue: base.b, alpha: base.a)
            let lightVinyl = (base.r + base.g + base.b) / 3 > 0.5 && color != .clear

            // 1. La matière.
            c.saveGState()
            c.addEllipse(in: circle(0.998))
            c.clip()
            var rng = SeededRandom(seed: seed)
            switch color {
            case .picture:
                if let label { label.draw(in: CGRect(x: 0, y: 0, width: size, height: size)) }
                c.setFillColor(UIColor(white: 0, alpha: 0.08).cgColor)
                c.fill(CGRect(x: 0, y: 0, width: size, height: size))
            case .marble:
                c.setFillColor(baseColor.cgColor)
                c.fill(CGRect(x: 0, y: 0, width: size, height: size))
                let tints = [UIColor(red: 0.16, green: 0.22, blue: 0.5, alpha: 0.55), UIColor(white: 0.55, alpha: 0.45),
                             UIColor(red: 0.08, green: 0.1, blue: 0.22, alpha: 0.5)]
                c.setShadow(offset: .zero, blur: 18, color: UIColor(white: 0, alpha: 0.25).cgColor)
                for i in 0..<34 {
                    let path = UIBezierPath()
                    let a0 = rng.next(0, 2 * .pi)
                    let r0 = rng.next(0.1, 0.95) * Double(R)
                    path.move(to: CGPoint(x: Double(R) + cos(a0) * r0, y: Double(R) + sin(a0) * r0))
                    for _ in 0..<3 {
                        let a = rng.next(0, 2 * .pi), r = rng.next(0.05, 1.0) * Double(R)
                        let a2 = rng.next(0, 2 * .pi), r2 = rng.next(0.05, 1.0) * Double(R)
                        let a3 = rng.next(0, 2 * .pi), r3 = rng.next(0.05, 1.0) * Double(R)
                        path.addCurve(to: CGPoint(x: Double(R) + cos(a) * r, y: Double(R) + sin(a) * r),
                                      controlPoint1: CGPoint(x: Double(R) + cos(a2) * r2, y: Double(R) + sin(a2) * r2),
                                      controlPoint2: CGPoint(x: Double(R) + cos(a3) * r3, y: Double(R) + sin(a3) * r3))
                    }
                    c.setStrokeColor(tints[i % tints.count].cgColor)
                    c.setLineWidth(CGFloat(rng.next(6, 60)))
                    c.setLineCap(.round)
                    c.addPath(path.cgPath)
                    c.strokePath()
                }
                c.setShadow(offset: .zero, blur: 0, color: nil)
            case .splatter:
                c.setFillColor(baseColor.cgColor)
                c.fill(CGRect(x: 0, y: 0, width: size, height: size))
                let inks = [UIColor(red: 0.85, green: 0.08, blue: 0.18, alpha: 1), UIColor(white: 0.06, alpha: 1),
                            UIColor(red: 0.1, green: 0.3, blue: 0.85, alpha: 1)]
                for i in 0..<70 {
                    let ink = inks[i % inks.count]
                    let a = rng.next(0, 2 * .pi), r = rng.next(0.36, 0.98) * Double(R)
                    let p = CGPoint(x: Double(R) + cos(a) * r, y: Double(R) + sin(a) * r)
                    let big = CGFloat(rng.next(8, 46))
                    c.setFillColor(ink.cgColor)
                    c.fillEllipse(in: CGRect(x: p.x - big / 2, y: p.y - big / 2, width: big, height: big * CGFloat(rng.next(0.7, 1.3))))
                    // Gouttelettes autour de la tache.
                    for _ in 0..<7 {
                        let d = CGFloat(rng.next(Double(big) * 0.6, Double(big) * 2.2))
                        let aa = rng.next(0, 2 * .pi)
                        let drop = CGFloat(rng.next(2, 9))
                        c.fillEllipse(in: CGRect(x: p.x + CGFloat(cos(aa)) * d, y: p.y + CGFloat(sin(aa)) * d, width: drop, height: drop))
                    }
                }
            default:
                c.setFillColor(baseColor.cgColor)
                c.fill(CGRect(x: 0, y: 0, width: size, height: size))
            }
            c.restoreGState()

            // 2. Les sillons : fines lignes concentriques, plus serrées au milieu de chaque morceau.
            let outer: CGFloat = 0.975, inner: CGFloat = 0.36
            let dark = UIColor(white: 0, alpha: lightVinyl ? 0.16 : 0.5).cgColor
            let light = UIColor(white: 1, alpha: lightVinyl ? 0.1 : 0.05).cgColor
            for (k, stroke) in [dark, light].enumerated() {
                let path = CGMutablePath()
                var r = inner * R + CGFloat(k) * 0.9
                while r < outer * R {
                    path.addEllipse(in: CGRect(x: R - r, y: R - r, width: 2 * r, height: 2 * r))
                    r += 2.1
                }
                c.addPath(path)
                c.setStrokeColor(stroke)
                c.setLineWidth(0.7)
                c.strokePath()
            }
            // Séparations entre les morceaux : une bande lisse et brillante.
            if let side, side.tracks.count > 1 {
                var elapsed = 0.0
                let total = max(1, side.duration)
                for t in side.tracks.dropLast() {
                    elapsed += t.duration
                    let f = outer - (outer - inner) * CGFloat(elapsed / total)
                    let r = f * R
                    c.setStrokeColor(baseColor.withAlphaComponent(max(0.6, base.a)).cgColor)
                    c.setLineWidth(5 * px)
                    c.strokeEllipse(in: CGRect(x: R - r, y: R - r, width: 2 * r, height: 2 * r))
                    c.setStrokeColor(UIColor(white: 1, alpha: lightVinyl ? 0.2 : 0.13).cgColor)
                    c.setLineWidth(1.2)
                    c.strokeEllipse(in: CGRect(x: R - r, y: R - r, width: 2 * r, height: 2 * r))
                }
            }
            // Bord d'entrée et zone de fin (lisses).
            c.setStrokeColor(baseColor.withAlphaComponent(max(0.6, base.a)).cgColor)
            c.setLineWidth(R * 0.02)
            c.strokeEllipse(in: circle(0.987))
            c.setStrokeColor(UIColor(white: 1, alpha: 0.06).cgColor)
            c.setLineWidth(1.5)
            c.strokeEllipse(in: circle(0.976))
            c.strokeEllipse(in: circle(0.36))
            // Numéro de matrice gravé dans la zone de fin.
            let etch: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 11 * px, weight: .medium),
                .foregroundColor: UIColor(white: lightVinyl ? 0 : 1, alpha: 0.28)
            ]
            let matrix = catalog.replacingOccurrences(of: " ", with: "-") + "-" + letter + "1  ·  PLATINE PRESSAGE"
            var angle: CGFloat = .pi * 0.15
            let radius = R * 0.348
            for ch in matrix {
                let str = String(ch) as NSString
                let w = str.size(withAttributes: etch).width
                let step = (w + 1) / radius
                angle += step / 2
                c.saveGState()
                c.translateBy(x: R, y: R)
                c.rotate(by: angle + .pi / 2)
                str.draw(at: CGPoint(x: -w / 2, y: -radius - 6 * px), withAttributes: etch)
                c.restoreGState()
                angle += step / 2
            }

            // 3. L'étiquette (100 mm).
            let lr = R * 0.333
            let labelRect = CGRect(x: R - lr, y: R - lr, width: 2 * lr, height: 2 * lr)
            c.saveGState()
            c.addEllipse(in: labelRect)
            c.clip()
            if let label {
                let iw = label.size.width, ih = label.size.height
                let k = max(labelRect.width / max(iw, 1), labelRect.height / max(ih, 1))
                label.draw(in: CGRect(x: R - iw * k / 2, y: R - ih * k / 2, width: iw * k, height: ih * k))
            } else {
                c.setFillColor(UIColor(white: 0.9, alpha: 1).cgColor)
                c.fill(labelRect)
            }
            // Bas de l'étiquette assombri pour lire le texte imprimé.
            let shade = [UIColor(white: 0, alpha: 0).cgColor, UIColor(white: 0, alpha: 0.62).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: shade, locations: [0, 1]) {
                c.drawLinearGradient(grad, start: CGPoint(x: R, y: R - lr * 0.1), end: CGPoint(x: R, y: R + lr), options: [])
            }
            c.restoreGState()
            c.setStrokeColor(UIColor(white: 0, alpha: 0.35).cgColor)
            c.setLineWidth(2)
            c.strokeEllipse(in: labelRect)

            func text(_ s: String, _ y: CGFloat, size: CGFloat, weight: UIFont.Weight, alpha: CGFloat = 1, x: CGFloat? = nil) {
                let a = NSAttributedString(string: s, attributes: [
                    .font: UIFont.systemFont(ofSize: size * px, weight: weight),
                    .foregroundColor: UIColor(white: 1, alpha: alpha),
                    .kern: 0.6
                ])
                let b = a.size()
                let maxW = lr * 1.5
                let k = min(1, maxW / max(b.width, 1))
                c.saveGState()
                let px = x ?? (R - b.width * k / 2)
                c.translateBy(x: px, y: y - b.height * k / 2)
                c.scaleBy(x: k, y: k)
                a.draw(at: .zero)
                c.restoreGState()
            }
            let duration = side.map { formatDuration($0.duration) } ?? "—"
            text(letter, R + lr * 0.26, size: 46, weight: .heavy, x: R - lr * 0.74)
            text("33⅓", R + lr * 0.26, size: 20, weight: .bold, alpha: 0.9, x: R + lr * 0.42)
            text(artist.uppercased(), R + lr * 0.3, size: 17, weight: .heavy)
            text(title, R + lr * 0.46, size: 14, weight: .semibold, alpha: 0.9)
            let lines = (side?.tracks ?? []).prefix(4).enumerated().map { "\($0.offset + 1). \($0.element.title)" }
            for (i, line) in lines.enumerated() {
                text(line, R + lr * (0.58 + CGFloat(i) * 0.085), size: 10, weight: .medium, alpha: 0.85)
            }
            let y = year > 0 ? String(year) : "—"
            text("FACE \(letter) · ℗ \(y) PLATINE · \(duration)", R + lr * 0.93, size: 9, weight: .semibold, alpha: 0.75)

            // 4. Le trou central (7,24 mm).
            c.setBlendMode(.clear)
            c.fillEllipse(in: circle(0.0245))
            _ = center
        }
    }

    /// Sticker rond collé sur le blister : « Inclut le single… » (ou ton texte).
    static func hypeSticker(text: String, single: String, discs: Int) -> UIImage {
        let s: CGFloat = 512
        // Dessiné en 1024 px (deux fois plus net), avec les mesures d'une image de 512.
        return renderer(CGSize(width: s * 2, height: s * 2)).image { ctx in
            let c = ctx.cgContext
            c.scaleBy(x: 2, y: 2)
            let rect = CGRect(x: 8, y: 8, width: s - 16, height: s - 16)
            c.setShadow(offset: CGSize(width: 0, height: 3), blur: 6, color: UIColor(white: 0, alpha: 0.35).cgColor)
            c.setFillColor(UIColor(red: 0.98, green: 0.84, blue: 0.12, alpha: 1).cgColor)
            c.fillEllipse(in: rect)
            c.setShadow(offset: .zero, blur: 0, color: nil)
            c.setStrokeColor(UIColor(white: 0, alpha: 0.85).cgColor)
            c.setLineWidth(5)
            c.strokeEllipse(in: rect.insetBy(dx: 16, dy: 16))
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            func draw(_ str: String, _ y: CGFloat, _ size: CGFloat, _ weight: UIFont.Weight, width: CGFloat = 380) {
                let a = NSAttributedString(string: str, attributes: [
                    .font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: UIColor(white: 0.05, alpha: 1),
                    .paragraphStyle: style
                ])
                let box = a.boundingRect(with: CGSize(width: width, height: 260), options: [.usesLineFragmentOrigin], context: nil)
                a.draw(with: CGRect(x: (s - width) / 2, y: y - box.height / 2, width: width, height: box.height),
                       options: [.usesLineFragmentOrigin], context: nil)
            }
            if !text.isEmpty {
                draw(text, s / 2, 44, .heavy, width: 360)
            } else {
                draw("INCLUT LE SINGLE", 150, 34, .heavy)
                draw("« \(single) »", 250, 46, .black, width: 380)
                draw(discs > 1 ? "DOUBLE VINYLE · 33 TOURS" : "VINYLE 180 G · 33 TOURS", 372, 24, .bold)
            }
            // Petit reflet du sticker brillant.
            c.setFillColor(UIColor(white: 1, alpha: 0.22).cgColor)
            c.fillEllipse(in: CGRect(x: 90, y: 60, width: 200, height: 70))
        }
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

    /// Double page intérieure du gatefold : photo à gauche, crédits et morceaux à droite.
    static func innerSpread(album: AlbumInfo, sides: [VinylSide], cover: UIImage?, catalog: String) -> UIImage {
        let w: CGFloat = 2048, h: CGFloat = 1024
        return renderer(CGSize(width: w, height: h), opaque: true).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(white: 0.06, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            if let cover {
                cover.draw(in: CGRect(x: -120, y: -120, width: 1264, height: 1264))
                let fade = [UIColor(white: 0, alpha: 0).cgColor, UIColor(white: 0, alpha: 0.75).cgColor] as CFArray
                if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: fade, locations: [0.2, 1]) {
                    c.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [])
                }
            }
            NSAttributedString(string: album.artist.uppercased(), attributes: [
                .font: UIFont.systemFont(ofSize: 70, weight: .black), .foregroundColor: UIColor.white, .kern: 4
            ]).draw(in: CGRect(x: 70, y: h - 250, width: 900, height: 90))
            NSAttributedString(string: album.title, attributes: [
                .font: UIFont.systemFont(ofSize: 46, weight: .medium), .foregroundColor: UIColor(white: 1, alpha: 0.85)
            ]).draw(in: CGRect(x: 70, y: h - 160, width: 900, height: 70))
            // Page de droite.
            var y: CGFloat = 90
            for side in sides where !side.tracks.isEmpty {
                NSAttributedString(string: "FACE \(side.letter)", attributes: [
                    .font: UIFont.systemFont(ofSize: 30, weight: .heavy), .foregroundColor: UIColor(white: 1, alpha: 0.95), .kern: 3
                ]).draw(at: CGPoint(x: 1124 + 60, y: y))
                y += 48
                for (i, t) in side.tracks.enumerated() {
                    guard y < h - 200 else { break }
                    NSAttributedString(string: "\(i + 1). \(t.title)", attributes: [
                        .font: UIFont.systemFont(ofSize: 24, weight: .medium), .foregroundColor: UIColor(white: 1, alpha: 0.8)
                    ]).draw(in: CGRect(x: 1124 + 60, y: y, width: 680, height: 32))
                    NSAttributedString(string: formatTime(t.duration), attributes: [
                        .font: UIFont.monospacedDigitSystemFont(ofSize: 22, weight: .regular), .foregroundColor: UIColor(white: 1, alpha: 0.55)
                    ]).draw(at: CGPoint(x: w - 170, y: y + 2))
                    y += 34
                }
                y += 26
            }
            let year = album.year > 0 ? String(album.year) : ""
            let credits = "Produit par \(album.artist). Pochette et mise en page : Platine Studio. Pressé sur vinyle 180 g.\n℗ \(year) © \(year) Platine Records · \(catalog) · Fabriqué dans l’UE."
            NSAttributedString(string: credits, attributes: [
                .font: UIFont.systemFont(ofSize: 19), .foregroundColor: UIColor(white: 1, alpha: 0.5)
            ]).draw(in: CGRect(x: 1124 + 60, y: h - 150, width: 820, height: 110))
            // Pli central.
            c.setFillColor(UIColor(white: 0, alpha: 0.4).cgColor)
            c.fill(CGRect(x: w / 2 - 4, y: 0, width: 8, height: h))
        }
    }

    /// Bois (noyer foncé pour la platine, pin clair pour le bac).
    static func wood(dark: Bool) -> UIImage {
        let key = dark ? "wood-dark" : "wood-light"
        if let img = AlbumNodeBuilder.textures.object(forKey: key as NSString) { return img }
        let w: CGFloat = 512, h: CGFloat = 512
        let img = renderer(CGSize(width: w, height: h), opaque: true).image { ctx in
            let c = ctx.cgContext
            let baseColor = dark ? UIColor(red: 0.27, green: 0.15, blue: 0.08, alpha: 1) : UIColor(red: 0.72, green: 0.55, blue: 0.36, alpha: 1)
            c.setFillColor(baseColor.cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            var rng = SeededRandom(seed: dark ? 5 : 6)
            for _ in 0..<160 {
                let y = rng.next(0, Double(h))
                let amp = rng.next(2, 10)
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 0, y: y))
                var x = 0.0
                while x < Double(w) {
                    x += 32
                    path.addLine(to: CGPoint(x: x, y: y + sin(x / 60 + y) * amp))
                }
                c.setStrokeColor(UIColor(white: rng.next(0, 1) > 0.5 ? 0 : 1, alpha: CGFloat(rng.next(0.03, 0.12))).cgColor)
                c.setLineWidth(CGFloat(rng.next(0.6, 3)))
                c.addPath(path.cgPath)
                c.strokePath()
            }
        }
        AlbumNodeBuilder.textures.setObject(img, forKey: key as NSString)
        return img
    }

    /// Côté du bac, avec sa poignée découpée.
    static let crateSide: UIImage = {
        let base = wood(dark: false)
        return renderer(CGSize(width: 512, height: 256), opaque: true).image { ctx in
            base.draw(in: CGRect(x: 0, y: 0, width: 512, height: 512))
            let handle = UIBezierPath(roundedRect: CGRect(x: 176, y: 40, width: 160, height: 44), cornerRadius: 22)
            ctx.cgContext.setFillColor(UIColor(white: 0.03, alpha: 1).cgColor)
            ctx.cgContext.addPath(handle.cgPath)
            ctx.cgContext.fillPath()
        }
    }()

    /// Carte du disquaire sur l'avant du bac.
    static let crateCard: UIImage = {
        renderer(CGSize(width: 700, height: 200), opaque: true).image { ctx in
            ctx.cgContext.setFillColor(UIColor(white: 0.96, alpha: 1).cgColor)
            ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 700, height: 200))
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            NSAttributedString(string: "VINYLES", attributes: [
                .font: UIFont.systemFont(ofSize: 78, weight: .black), .foregroundColor: UIColor(white: 0.08, alpha: 1), .kern: 10,
                .paragraphStyle: style
            ]).draw(in: CGRect(x: 0, y: 18, width: 700, height: 100))
            NSAttributedString(string: "PLATINE DISQUES · A – Z", attributes: [
                .font: UIFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: UIColor(red: 0.8, green: 0.08, blue: 0.1, alpha: 1),
                .kern: 4, .paragraphStyle: style
            ]).draw(in: CGRect(x: 0, y: 124, width: 700, height: 50))
        }
    }()
}

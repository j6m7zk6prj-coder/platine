import SwiftUI
import SceneKit
import UIKit

// MARK: - Les objets de la Collection

/// Objets qu'on peut ranger dans la Collection et manipuler (la musique y joue en direct).
enum CollectionObject: String, CaseIterable, Identifiable {
    case phone8Black

    var id: String { rawValue }
    var name: String {
        switch self {
        case .phone8Black: return "Téléphone 8"
        }
    }
    var finish: String {
        switch self {
        case .phone8Black: return "Noir sidéral · 2017"
        }
    }
    var symbol: String {
        switch self {
        case .phone8Black: return "iphone.gen1"
        }
    }

    /// Largeur ÷ hauteur du dos (pour placer les stickers).
    var backAspect: CGFloat { 67.3 / 138.4 }

    /// Un « album » fictif qui sert à ranger les stickers collés au dos de l'objet.
    var stickerAlbum: AlbumInfo {
        let placeholder = Track(title: name, artist: "", album: "", duration: 0, audioFile: "", addedAt: .distantPast)
        return AlbumInfo(id: "object:" + rawValue, title: name, artist: "", year: 0, tracks: [placeholder])
    }

    /// Le dos du téléphone, à plat (fond de l'écran de placement des stickers).
    var backImage: UIImage {
        let size = CGSize(width: 337, height: 692)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            UIColor(white: 0.07, alpha: 1).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 50).fill()
            // Reflet du verre.
            let colors = [UIColor(white: 1, alpha: 0.08).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height * 0.6), options: [])
            }
            // Appareil photo et flash, en haut à gauche (vus de dos).
            UIColor(white: 0.25, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 27, y: 27, width: 46, height: 46)).fill()
            UIColor(white: 0.02, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 33, y: 33, width: 34, height: 34)).fill()
            UIColor(red: 0.95, green: 0.9, blue: 0.75, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 92, y: 42, width: 16, height: 16)).fill()
        }
    }

    private static let key = "collectionObjects"

    static func loadOwned() -> [CollectionObject] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(CollectionObject.init(rawValue:))
    }

    static func saveOwned(_ list: [CollectionObject]) {
        UserDefaults.standard.set(list.map(\.rawValue), forKey: key)
    }
}

/// Section « Objets » de la Collection.
struct ObjectsRoom: View {
    var active: Bool
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(AppSettings.self) private var settings
    @State private var owned: [CollectionObject] = CollectionObject.loadOwned()
    @State private var showCatalog = false
    @State private var volume = VolumeModel()
    @State private var stickerTarget: AlbumInfo?
    @State private var flipToken = 0

    var body: some View {
        ZStack {
            if let object = owned.first {
                PhoneSceneView(object: object, active: active, volume: volume, flipToken: flipToken)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    Spacer()
                    VStack(spacing: 4) {
                        Text(object.name).font(.title2.bold())
                        Text(object.finish).font(.headline).foregroundStyle(.white.opacity(0.6))
                        Text("Touche l’écran pour lire ou mettre en pause · ◀︎ ▶︎ pour changer de son · bouton du bas, volume et verrouillage marchent aussi")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                            .padding(.top, 4)
                    }
                    HStack(spacing: 12) {
                        Button {
                            stickerTarget = object.stickerAlbum
                        } label: {
                            Label("Stickers au dos", systemImage: "seal.fill")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 11)
                                .glassCapsule()
                        }
                        Button(role: .destructive) {
                            withAnimation(.smooth) {
                                owned.removeAll { $0 == object }
                                CollectionObject.saveOwned(owned)
                            }
                        } label: {
                            Label("Retirer", systemImage: "trash")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 11)
                                .glassCapsule()
                        }
                    }
                    .buttonStyle(PressStyle(circle: false))
                }
                .padding(.bottom, 30)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "iphone.gen1")
                        .font(.system(size: 54, weight: .light))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Aucun objet").font(.title2.bold())
                    Text("Ajoute un appareil : la musique en cours s’y joue en direct, et ses boutons marchent pour de vrai.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button { showCatalog = true } label: {
                        Label("Ajouter un objet", systemImage: "plus")
                            .font(.headline)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 12)
                            .glassCapsule(interactive: true)
                    }
                    .buttonStyle(PressStyle(circle: false))
                }
            }
        }
        .background { HiddenVolumeView(model: volume).frame(width: 1, height: 1).opacity(0.01) }
        // En refermant les stickers, le téléphone se retourne pour montrer son dos.
        .sheet(item: $stickerTarget, onDismiss: { flipToken += 1 }) { album in
            StickerPicker(album: album)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .environment(\.colorScheme, .dark)
        }
        .sheet(isPresented: $showCatalog) {
            ObjectCatalog(owned: owned) { object in
                withAnimation(.smooth) {
                    if !owned.contains(object) { owned.append(object) }
                    CollectionObject.saveOwned(owned)
                }
                showCatalog = false
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .environment(\.colorScheme, .dark)
        }
    }
}

/// Le choix des objets à ajouter.
struct ObjectCatalog: View {
    let owned: [CollectionObject]
    var onAdd: (CollectionObject) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(CollectionObject.allCases) { object in
                        let has = owned.contains(object)
                        Button { onAdd(object) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: object.symbol)
                                    .font(.title2)
                                    .frame(width: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(object.name).font(.body.weight(.semibold))
                                    Text(object.finish).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: has ? "checkmark.circle.fill" : "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(has ? Color.green : Color.white)
                            }
                        }
                        .disabled(has)
                    }
                } footer: {
                    Text("D’autres objets arrivent bientôt : baladeur à molette, platine vinyle…")
                }
            }
            .navigationTitle("Ajouter un objet")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Le téléphone en 3D

struct PhoneSceneView: UIViewRepresentable {
    let object: CollectionObject
    var active: Bool
    let volume: VolumeModel
    var flipToken = 0
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player

    func makeCoordinator() -> PhoneSceneController { PhoneSceneController() }

    /// Les stickers du dos, redessinés seulement quand ils changent.
    private func updateStickers(_ c: PhoneSceneController) {
        let album = object.stickerAlbum
        let badges = library.badges(for: album)
        let keys = library.stickerOrder(for: album, badges: badges)
        let signature = keys.joined(separator: ",") + "|" + library.placementSignature(album.id)
        guard signature != c.stickerSignature else { return }
        c.stickerSignature = signature
        guard !keys.isEmpty else { c.setBackStickers(nil); return }
        let size = CGSize(width: 337, height: 692)
        let layer = PlacedStickers(album: album, badges: badges, size: size)
            .environment(library)
        let renderer = ImageRenderer(content: layer)
        renderer.scale = 2
        renderer.isOpaque = false
        c.setBackStickers(renderer.uiImage)
    }

    func makeUIView(context: Context) -> SCNView {
        let c = context.coordinator
        c.library = library
        c.player = player
        c.volume = volume
        c.setActive(active)
        c.refreshScreen()
        c.flipToken = flipToken
        updateStickers(c)
        return c.view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let c = context.coordinator
        c.volume = volume
        c.setActive(active)
        updateStickers(c)
        if flipToken != c.flipToken {
            c.flipToken = flipToken
            c.showBack()
        }
        // Nouveau morceau, lecture ou pause : l'écran se met à jour tout de suite.
        let state = (player.currentID?.uuidString ?? "-") + (player.isPlaying ? "▶︎" : "⏸")
        if state != c.lastState {
            c.lastState = state
            c.refreshScreen()
        }
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: PhoneSceneController) {
        coordinator.setActive(false)
    }
}

/// Dimensions réelles du téléphone (en mm, 1 mm = 0,01 unité).
private enum Phone {
    static let width: CGFloat = 0.673
    static let height: CGFloat = 1.384
    static let depth: CGFloat = 0.073
    static let corner: CGFloat = 0.1
    /// Écran 4,7 pouces : 58,5 × 104,1 mm.
    static let screen = CGSize(width: 0.585, height: 1.041)
    static let screenPixels = CGSize(width: 375, height: 667)
}

@MainActor
final class PhoneSceneController: NSObject, UIGestureRecognizerDelegate {
    let view = SCNView()
    let scene = SCNScene()
    weak var library: Library?
    weak var player: Player?
    var volume: VolumeModel?
    var lastState = ""
    var stickerSignature = "-"
    var flipToken = 0
    private let stickerMaterial = SCNMaterial()
    private var stickerNode: SCNNode?

    private let cameraNode = SCNNode()
    private let holder = SCNNode()
    private let screenMaterial = SCNMaterial()
    private var homeNode = SCNNode()
    private var buttons: [String: SCNNode] = [:]
    private var screenOn = true
    private var link: CADisplayLink?
    private var lastTime: CFTimeInterval = 0
    private var sinceRefresh: CFTimeInterval = 0
    private var active = false

    // Rotation guidée par un ressort (comme les CD).
    private let restX = -0.08, restY = 0.32
    private var rx = -0.08, ry = 0.32, tx = -0.08, ty = 0.32, vx = 0.0, vy = 0.0
    private var startX = 0.0, startY = 0.0
    private var dragging = false
    private var zoom = 1.0, zoomTarget = 1.0, pinchStart = 1.0

    override init() {
        super.init()
        Studio.addLights(to: scene, withFloor: false)
        let camera = SCNCamera()
        camera.fieldOfView = 30
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 5.8)
        scene.rootNode.addChildNode(cameraNode)
        // Bien centré entre le titre et les boutons du bas : on le voit en entier.
        holder.position = SCNVector3(0, 0.2, 0)
        scene.rootNode.addChildNode(holder)
        holder.addChildNode(buildPhone())

        // Ombre douce derrière l'objet.
        let shadow = SCNPlane(width: 2.2, height: 2.8)
        let sm = SCNMaterial()
        sm.lightingModel = .constant
        sm.diffuse.contents = InspectorSceneController.softShadow
        sm.writesToDepthBuffer = false
        shadow.materials = [sm]
        let shadowNode = SCNNode(geometry: shadow)
        shadowNode.position = SCNVector3(0.06, 0.1, -0.8)
        shadowNode.renderingOrder = -1
        shadowNode.opacity = 0.65
        scene.rootNode.addChildNode(shadowNode)

        view.scene = scene
        view.pointOfView = cameraNode
        view.configureForShelf()
        view.antialiasingMode = .multisampling4X

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        for g in [pan, tap, pinch] as [UIGestureRecognizer] {
            g.delegate = self
            g.cancelsTouchesInView = false
            view.addGestureRecognizer(g)
        }
    }

    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        MainActor.assumeIsolated {
            let p = touch.location(in: view)
            return p.y > 120 && p.y < view.bounds.height - 190
        }
    }

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
            lastTime = 0
            view.isPlaying = true
            view.rendersContinuously = true
            refreshScreen()
        } else {
            link?.invalidate()
            link = nil
            view.isPlaying = false
            view.rendersContinuously = false
        }
    }

    // MARK: Fabrication

    private func buildPhone() -> SCNNode {
        let phone = SCNNode()
        let W = Phone.width, H = Phone.height, D = Phone.depth

        // Corps : verre noir devant, verre sombre derrière, bande en aluminium gris sidéral sur les côtés.
        let path = UIBezierPath(roundedRect: CGRect(x: -W / 2, y: -H / 2, width: W, height: H), cornerRadius: Phone.corner)
        path.flatness = 0.001
        let body = SCNShape(path: path, extrusionDepth: D)
        // Côtés bien arrondis : l'aluminium fait le tour en arrondi, le verre est à plat devant et derrière.
        body.chamferRadius = 0.03
        body.chamferMode = .both
        let profile = UIBezierPath()
        profile.move(to: CGPoint(x: 0, y: 1))
        profile.addQuadCurve(to: CGPoint(x: 1, y: 0), controlPoint: CGPoint(x: 1, y: 1))
        body.chamferProfile = profile
        let front = Self.glass(white: 0.015)
        // Dos en verre gris sidéral (gris foncé, pas noir), comme sur la photo.
        let back = Self.glass(white: 0.11)
        let band = Self.metal()
        body.materials = [front, back, band, band, band]
        phone.addChildNode(SCNNode(geometry: body))

        let fz = Float(D / 2)

        // Écran : la musique en cours, en direct.
        let screen = SCNPlane(width: Phone.screen.width, height: Phone.screen.height)
        screenMaterial.lightingModel = .constant
        screenMaterial.diffuse.contents = UIColor.black
        screen.materials = [screenMaterial]
        let screenNode = SCNNode(geometry: screen)
        screenNode.name = "screen"
        screenNode.position = SCNVector3(0, 0.005, fz + 0.0006)
        phone.addChildNode(screenNode)

        // Reflet du verre par-dessus l'écran.
        let gloss = SCNPlane(width: W - 0.06, height: H - 0.06)
        gloss.cornerRadius = Phone.corner - 0.03
        let gm = SCNMaterial()
        gm.lightingModel = .blinn
        gm.diffuse.contents = UIColor.black
        gm.specular.contents = UIColor(white: 0.9, alpha: 1)
        gm.shininess = 0.9
        gm.blendMode = .add
        gm.writesToDepthBuffer = false
        gloss.materials = [gm]
        let glossNode = SCNNode(geometry: gloss)
        glossNode.position = SCNVector3(0, 0, fz + 0.0012)
        glossNode.renderingOrder = 10
        phone.addChildNode(glossNode)

        // Écouteur et caméra avant.
        let ear = SCNPlane(width: 0.105, height: 0.011)
        ear.cornerRadius = 0.0055
        ear.materials = [Self.flat(UIColor(white: 0.12, alpha: 1))]
        let earNode = SCNNode(geometry: ear)
        earNode.position = SCNVector3(0, Float(H / 2 - 0.085), fz + 0.0008)
        phone.addChildNode(earNode)
        // Grille de l'écouteur : fines perforations.
        let mesh = SCNPlane(width: 0.095, height: 0.006)
        mesh.cornerRadius = 0.003
        mesh.materials = [Self.flat(UIColor(white: 0.2, alpha: 1))]
        let meshNode = SCNNode(geometry: mesh)
        meshNode.position = SCNVector3(0, Float(H / 2 - 0.085), fz + 0.001)
        phone.addChildNode(meshNode)
        // Caméra avant (avec son petit reflet bleuté) et capteur de proximité au-dessus de l'écouteur.
        let cam = SCNPlane(width: 0.026, height: 0.026)
        cam.cornerRadius = 0.013
        cam.materials = [Self.flat(UIColor(red: 0.06, green: 0.06, blue: 0.12, alpha: 1))]
        let camNode = SCNNode(geometry: cam)
        camNode.position = SCNVector3(-0.09, Float(H / 2 - 0.085), fz + 0.0008)
        phone.addChildNode(camNode)
        let lensDot = SCNPlane(width: 0.012, height: 0.012)
        lensDot.cornerRadius = 0.006
        lensDot.materials = [Self.flat(UIColor(red: 0.12, green: 0.14, blue: 0.3, alpha: 1))]
        let lensDotNode = SCNNode(geometry: lensDot)
        lensDotNode.position = SCNVector3(-0.09, Float(H / 2 - 0.085), fz + 0.0011)
        phone.addChildNode(lensDotNode)
        let sensor = SCNPlane(width: 0.012, height: 0.012)
        sensor.cornerRadius = 0.006
        sensor.materials = [Self.flat(UIColor(white: 0.08, alpha: 1))]
        let sensorNode = SCNNode(geometry: sensor)
        sensorNode.position = SCNVector3(0, Float(H / 2 - 0.055), fz + 0.0008)
        phone.addChildNode(sensorNode)

        // Bouton principal : anneau métallique et disque de verre.
        homeNode = SCNNode()
        homeNode.name = "home"
        homeNode.position = SCNVector3(0, Float(-H / 2 + 0.085), fz)
        // Anneau arrondi en léger relief autour d'un disque de verre un peu creusé.
        let ring = SCNTorus(ringRadius: 0.053, pipeRadius: 0.0032)
        ring.materials = [Self.metal()]
        let ringNode = SCNNode(geometry: ring)
        ringNode.eulerAngles.x = .pi / 2
        ringNode.position.z = 0.0012
        ringNode.name = "home"
        homeNode.addChildNode(ringNode)
        let disc = SCNCylinder(radius: 0.051, height: 0.002)
        disc.materials = [Self.glass(white: 0.025)]
        let discNode = SCNNode(geometry: disc)
        discNode.eulerAngles.x = .pi / 2
        discNode.position.z = -0.0006
        discNode.name = "home"
        homeNode.addChildNode(discNode)
        phone.addChildNode(homeNode)

        // Dos en verre : reflet brillant par-dessus, et les stickers collés au dos.
        let bz = Float(-D / 2)
        let backW = W - 0.06, backH = H - 0.06
        let stickers = SCNPlane(width: backW, height: backH)
        stickers.cornerRadius = Phone.corner - 0.03
        stickerMaterial.lightingModel = .physicallyBased
        stickerMaterial.diffuse.contents = UIColor.clear
        stickerMaterial.roughness.contents = 0.25
        stickerMaterial.transparencyMode = .aOne
        stickerMaterial.writesToDepthBuffer = false
        stickers.materials = [stickerMaterial]
        let sNode = SCNNode(geometry: stickers)
        sNode.eulerAngles.y = .pi
        sNode.position = SCNVector3(0, 0, bz - 0.0006)
        sNode.isHidden = true
        phone.addChildNode(sNode)
        stickerNode = sNode
        let backGloss = SCNPlane(width: backW, height: backH)
        backGloss.cornerRadius = Phone.corner - 0.03
        backGloss.materials = [gm]
        let bgNode = SCNNode(geometry: backGloss)
        bgNode.eulerAngles.y = .pi
        bgNode.position = SCNVector3(0, 0, bz - 0.0012)
        bgNode.renderingOrder = 10
        phone.addChildNode(bgNode)

        // Dos : appareil photo (anneau en relief) et flash.
        let bump = SCNCylinder(radius: 0.046, height: 0.012)
        bump.materials = [Self.metal()]
        let bumpNode = SCNNode(geometry: bump)
        bumpNode.eulerAngles.x = .pi / 2
        bumpNode.position = SCNVector3(Float(-W / 2 + 0.1), Float(H / 2 - 0.1), bz - 0.004)
        phone.addChildNode(bumpNode)
        let lens = SCNCylinder(radius: 0.034, height: 0.013)
        let lm = Self.glass(white: 0.01)
        lens.materials = [lm]
        let lensNode = SCNNode(geometry: lens)
        lensNode.eulerAngles.x = .pi / 2
        lensNode.position = bumpNode.position
        lensNode.position.z -= 0.0008
        phone.addChildNode(lensNode)
        let flash = SCNPlane(width: 0.032, height: 0.032)
        flash.cornerRadius = 0.016
        flash.materials = [Self.flat(UIColor(red: 0.95, green: 0.9, blue: 0.75, alpha: 1))]
        let flashNode = SCNNode(geometry: flash)
        flashNode.eulerAngles.y = .pi
        flashNode.position = SCNVector3(Float(-W / 2 + 0.2), Float(H / 2 - 0.1), bz - 0.0008)
        phone.addChildNode(flashNode)

        // Boutons sur les côtés : silencieux et volume à gauche, verrouillage à droite.
        // Boutons en forme de pilule, bien arrondis, qui dépassent à peine de la tranche.
        func sideButton(_ name: String, x: CGFloat, y: CGFloat, length: CGFloat) {
            let b = SCNBox(width: 0.014, height: length, length: 0.024, chamferRadius: 0.0068)
            b.materials = [Self.metal()]
            let n = SCNNode(geometry: b)
            n.name = name
            n.position = SCNVector3(Float(x), Float(y), 0)
            phone.addChildNode(n)
            buttons[name] = n
        }
        // Bouton silencieux : un petit interrupteur dans son logement creusé.
        let slot = SCNBox(width: 0.008, height: 0.062, length: 0.026, chamferRadius: 0.004)
        slot.materials = [Self.flat(UIColor(white: 0.04, alpha: 1))]
        let slotNode = SCNNode(geometry: slot)
        slotNode.position = SCNVector3(Float(-W / 2 + 0.001), 0.47, 0)
        phone.addChildNode(slotNode)
        sideButton("mute", x: -W / 2 - 0.0005, y: 0.477, length: 0.03)
        sideButton("volumeUp", x: -W / 2 - 0.002, y: 0.32, length: 0.09)
        sideButton("volumeDown", x: -W / 2 - 0.002, y: 0.2, length: 0.09)
        sideButton("power", x: W / 2 + 0.002, y: 0.32, length: 0.11)

        // Lignes d'antenne : fines bandes sombres sur la tranche, en haut et en bas.
        let antenna = Self.flat(UIColor(white: 0.12, alpha: 1))
        for y in [H / 2 - 0.115, -H / 2 + 0.115] {
            for x in [-W / 2 - 0.0002, W / 2 + 0.0002] {
                let line = SCNBox(width: 0.003, height: 0.004, length: 0.03, chamferRadius: 0.0015)
                line.materials = [antenna]
                let n = SCNNode(geometry: line)
                n.position = SCNVector3(Float(x), Float(y), 0)
                phone.addChildNode(n)
            }
        }

        // Dessous : prise et grilles du haut-parleur.
        let port = SCNBox(width: 0.08, height: 0.006, length: 0.03, chamferRadius: 0.003)
        port.materials = [Self.flat(UIColor(white: 0.02, alpha: 1))]
        let portNode = SCNNode(geometry: port)
        portNode.position = SCNVector3(0, Float(-H / 2 + 0.001), 0)
        phone.addChildNode(portNode)
        let holeMaterial = Self.flat(UIColor(white: 0.02, alpha: 1))
        for side in [-1.0, 1.0] {
            for i in 0..<6 {
                let hole = SCNCylinder(radius: 0.0055, height: 0.004)
                hole.materials = [holeMaterial]
                let h = SCNNode(geometry: hole)
                h.position = SCNVector3(Float(side * (0.1 + Double(i) * 0.017)), Float(-H / 2 + 0.0005), 0)
                phone.addChildNode(h)
            }
            // Les deux petites vis de chaque côté de la prise.
            let screw = SCNCylinder(radius: 0.005, height: 0.003)
            screw.materials = [Self.metal()]
            let sc = SCNNode(geometry: screw)
            sc.position = SCNVector3(Float(side * 0.072), Float(-H / 2 + 0.0002), 0)
            phone.addChildNode(sc)
        }
        // Micro du dos, entre l'appareil photo et le flash.
        let mic = SCNPlane(width: 0.009, height: 0.009)
        mic.cornerRadius = 0.0045
        mic.materials = [holeMaterial]
        let micNode = SCNNode(geometry: mic)
        micNode.eulerAngles.y = .pi
        micNode.position = SCNVector3(Float(-W / 2 + 0.152), Float(H / 2 - 0.1), Float(-D / 2) - 0.0008)
        phone.addChildNode(micNode)
        return phone
    }

    private static func glass(white: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: white, alpha: 1)
        m.roughness.contents = 0.04
        m.metalness.contents = 0.0
        m.clearCoat.contents = 1.0
        m.clearCoatRoughness.contents = 0.02
        return m
    }

    private static func metal() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        // Aluminium anodisé gris sidéral.
        m.diffuse.contents = UIColor(red: 0.29, green: 0.3, blue: 0.32, alpha: 1)
        m.metalness.contents = 1.0
        m.roughness.contents = 0.38
        return m
    }

    private static func flat(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        return m
    }

    // MARK: Écran en direct

    func refreshScreen() {
        sinceRefresh = 0
        guard screenOn else {
            screenMaterial.diffuse.contents = UIColor.black
            return
        }
        guard let library, let player else { return }
        let track = player.currentID.flatMap { library.track($0) }
        let screen = PhoneScreenContent(
            title: track?.title ?? "Platine",
            artist: track?.displayArtist ?? "Aucun morceau",
            artwork: track.flatMap { library.image(for: $0) },
            playing: player.isPlaying,
            time: player.currentTime,
            duration: player.duration,
            explicit: track?.explicit ?? false)
            .frame(width: Phone.screenPixels.width, height: Phone.screenPixels.height)
        let renderer = ImageRenderer(content: screen)
        renderer.scale = 2
        if let image = renderer.uiImage {
            screenMaterial.diffuse.contents = image
        }
    }

    // MARK: Animation

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = lastTime == 0 ? 1.0 / 120 : min(max(now - lastTime, 1.0 / 240), 1.0 / 30)
        lastTime = now
        if !dragging {
            let k = 150.0, c = 2 * k.squareRoot() * 0.86
            vx += (k * (tx - rx) - c * vx) * dt
            vy += (k * (ty - ry) - c * vy) * dt
            rx += vx * dt
            ry += vy * dt
        }
        zoom += (zoomTarget - zoom) * min(1, dt * 12)
        holder.eulerAngles = SCNVector3(Float(rx), Float(ry), 0)
        cameraNode.position = SCNVector3(0, 0, Float(5.8 / zoom))
        // La barre de progression avance chaque seconde.
        sinceRefresh += dt
        if sinceRefresh > 1, player?.isPlaying == true { refreshScreen() }
    }

    // MARK: Gestes

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view)
        switch g.state {
        case .began:
            dragging = true
            startX = rx
            startY = ry
        case .changed:
            ry = startY + Double(t.x) * 0.0095
            let tilt = Double(t.y) * 0.004
            rx = startX + tilt / (1 + abs(tilt) * 2.2)
            tx = rx
            ty = ry
        default:
            dragging = false
            let spin = (Double(g.velocity(in: view).x) * 0.0095).clamped(-22, 22)
            let projected = ry + spin * 0.22
            let face = ((projected - restY) / .pi).rounded()
            ty = restY + face * .pi
            tx = restX
            vx = 0
            vy = spin
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began: pinchStart = zoomTarget
        case .changed: zoomTarget = (pinchStart * Double(g.scale)).clamped(0.75, 1.8)
        default: zoomTarget = zoomTarget.clamped(0.85, 1.6)
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let hits = view.hitTest(g.location(in: view), options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
        guard let hit = hits.first, let name = hit.node.name else { return }
        let haptic = UIImpactFeedbackGenerator(style: .light)
        switch name {
        case "screen":
            guard screenOn else { wake(); return }
            // Les commandes sont en bas de l'écran : ◀︎ à gauche, ▶︎ à droite, lecture au centre.
            let local = hit.localCoordinates
            let u = Double(local.x) / Double(Phone.screen.width) + 0.5
            let v = 0.5 - Double(local.y) / Double(Phone.screen.height)
            if v > 0.76 && v < 0.96 && u < 0.33 {
                player?.previous()
            } else if v > 0.76 && v < 0.96 && u > 0.67 {
                player?.next()
            } else {
                player?.togglePlay()
            }
            haptic.impactOccurred()
        case "home":
            press(homeNode, axis: .z)
            if screenOn { player?.togglePlay() } else { wake() }
            haptic.impactOccurred(intensity: 0.9)
        case "power":
            press(buttons["power"], axis: .x)
            screenOn.toggle()
            refreshScreen()
            haptic.impactOccurred()
        case "volumeUp":
            press(buttons["volumeUp"], axis: .x)
            if let v = volume { v.set(min(1, v.volume + 0.0625)) }
            haptic.impactOccurred(intensity: 0.6)
        case "volumeDown":
            press(buttons["volumeDown"], axis: .x)
            if let v = volume { v.set(max(0, v.volume - 0.0625)) }
            haptic.impactOccurred(intensity: 0.6)
        case "mute":
            press(buttons["mute"], axis: .x)
            player?.togglePlay()
            haptic.impactOccurred(intensity: 0.7)
        default:
            break
        }
    }

    func setBackStickers(_ image: UIImage?) {
        stickerMaterial.diffuse.contents = image ?? UIColor.clear
        stickerNode?.isHidden = image == nil
    }

    /// Retourne le téléphone pour montrer son dos.
    func showBack() {
        let face = ((ty - restY) / .pi).rounded()
        let isFront = Int(face) % 2 == 0
        if isFront { ty = restY + (face + 1) * .pi }
        tx = restX
    }

    private func wake() {
        screenOn = true
        refreshScreen()
    }

    private enum Axis { case x, z }

    /// Le bouton s'enfonce puis remonte.
    private func press(_ node: SCNNode?, axis: Axis) {
        guard let node else { return }
        let base = node.position
        var pressed = base
        switch axis {
        case .x: pressed.x += base.x > 0 ? -0.004 : 0.004
        case .z: pressed.z -= 0.002
        }
        let down = SCNAction.move(to: pressed, duration: 0.06)
        down.timingMode = .easeOut
        let up = SCNAction.move(to: base, duration: 0.14)
        up.timingMode = .easeOut
        node.runAction(.sequence([down, up]), forKey: "press")
    }
}

// MARK: - Ce qu'affiche l'écran du téléphone

/// L'écran « En lecture » du téléphone, dessiné à sa taille réelle (375 × 667 points).
struct PhoneScreenContent: View {
    let title: String
    let artist: String
    let artwork: UIImage?
    let playing: Bool
    let time: Double
    let duration: Double
    let explicit: Bool

    var body: some View {
        ZStack {
            Color.black
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 375, height: 667)
                    .blur(radius: 40)
                    .opacity(0.55)
                    .clipped()
            }
            Color.black.opacity(0.25)
            VStack(spacing: 0) {
                HStack {
                    Text(Date.now.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Image(systemName: "battery.75percent").font(.system(size: 15))
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)

                Spacer(minLength: 0)

                Group {
                    if let artwork {
                        Image(uiImage: artwork).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color(white: 0.18)
                            Image(systemName: "music.note").font(.system(size: 80)).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
                .frame(width: playing ? 300 : 250, height: playing ? 300 : 250)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 12)

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 21, weight: .semibold)).lineLimit(1)
                        if explicit {
                            Text("E")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(.black)
                                .frame(width: 16, height: 16)
                                .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.6)))
                        }
                    }
                    Text(artist).font(.system(size: 19)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)

                VStack(spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.2))
                            Capsule().fill(.white.opacity(0.7))
                                .frame(width: geo.size.width * min(1, time / max(duration, 0.01)))
                        }
                    }
                    .frame(height: 6)
                    HStack {
                        Text(Self.format(time))
                        Spacer()
                        Text("-" + Self.format(max(0, duration - time)))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 28)
                .padding(.top, 18)

                HStack {
                    Image(systemName: "backward.fill")
                    Spacer()
                    Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 46))
                    Spacer()
                    Image(systemName: "forward.fill")
                }
                .font(.system(size: 32))
                .padding(.horizontal, 50)
                .frame(height: 90)
                .padding(.top, 8)

                Capsule().fill(.white.opacity(0.0)).frame(height: 30)
            }
        }
        .foregroundStyle(.white)
    }

    static func format(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let s = Int(t.rounded(.down))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

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

    var body: some View {
        ZStack {
            if let object = owned.first {
                PhoneSceneView(object: object, active: active, volume: volume)
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
                    Button(role: .destructive) {
                        withAnimation(.smooth) {
                            owned.removeAll { $0 == object }
                            CollectionObject.saveOwned(owned)
                        }
                    } label: {
                        Label("Retirer de la Collection", systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 11)
                            .glassCapsule()
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
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player

    func makeCoordinator() -> PhoneSceneController { PhoneSceneController() }

    func makeUIView(context: Context) -> SCNView {
        let c = context.coordinator
        c.library = library
        c.player = player
        c.volume = volume
        c.setActive(active)
        c.refreshScreen()
        return c.view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let c = context.coordinator
        c.volume = volume
        c.setActive(active)
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
        cameraNode.position = SCNVector3(0, 0, 4.4)
        scene.rootNode.addChildNode(cameraNode)
        holder.position = SCNVector3(0, 0.18, 0)
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
        body.chamferRadius = 0.017
        body.chamferMode = .both
        let profile = UIBezierPath()
        profile.move(to: CGPoint(x: 0, y: 1))
        profile.addQuadCurve(to: CGPoint(x: 1, y: 0), controlPoint: CGPoint(x: 1, y: 1))
        body.chamferProfile = profile
        let front = Self.glass(white: 0.015)
        let back = Self.glass(white: 0.06)
        let band = Self.metal()
        body.materials = [front, back, band, front, back]
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
        let gloss = SCNPlane(width: W - 0.04, height: H - 0.04)
        gloss.cornerRadius = Phone.corner - 0.02
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
        let cam = SCNPlane(width: 0.026, height: 0.026)
        cam.cornerRadius = 0.013
        cam.materials = [Self.flat(UIColor(red: 0.05, green: 0.05, blue: 0.09, alpha: 1))]
        let camNode = SCNNode(geometry: cam)
        camNode.position = SCNVector3(-0.1, Float(H / 2 - 0.085), fz + 0.0008)
        phone.addChildNode(camNode)

        // Bouton principal : anneau métallique et disque de verre.
        homeNode = SCNNode()
        homeNode.name = "home"
        homeNode.position = SCNVector3(0, Float(-H / 2 + 0.085), fz)
        let ring = SCNTube(innerRadius: 0.05, outerRadius: 0.056, height: 0.003)
        ring.materials = [Self.metal()]
        let ringNode = SCNNode(geometry: ring)
        ringNode.eulerAngles.x = .pi / 2
        ringNode.name = "home"
        homeNode.addChildNode(ringNode)
        let disc = SCNCylinder(radius: 0.05, height: 0.002)
        disc.materials = [Self.glass(white: 0.02)]
        let discNode = SCNNode(geometry: disc)
        discNode.eulerAngles.x = .pi / 2
        discNode.position.z = -0.0005
        discNode.name = "home"
        homeNode.addChildNode(discNode)
        phone.addChildNode(homeNode)

        // Dos : appareil photo (anneau en relief) et flash.
        let bz = Float(-D / 2)
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
        func sideButton(_ name: String, x: CGFloat, y: CGFloat, length: CGFloat) {
            let b = SCNBox(width: 0.012, height: length, length: 0.028, chamferRadius: 0.005)
            b.materials = [Self.metal()]
            let n = SCNNode(geometry: b)
            n.name = name
            n.position = SCNVector3(Float(x), Float(y), 0)
            phone.addChildNode(n)
            buttons[name] = n
        }
        sideButton("mute", x: -W / 2 - 0.002, y: 0.47, length: 0.055)
        sideButton("volumeUp", x: -W / 2 - 0.002, y: 0.33, length: 0.09)
        sideButton("volumeDown", x: -W / 2 - 0.002, y: 0.2, length: 0.09)
        sideButton("power", x: W / 2 + 0.002, y: 0.33, length: 0.11)

        // Dessous : prise et grilles du haut-parleur.
        let port = SCNBox(width: 0.08, height: 0.006, length: 0.03, chamferRadius: 0.003)
        port.materials = [Self.flat(UIColor(white: 0.02, alpha: 1))]
        let portNode = SCNNode(geometry: port)
        portNode.position = SCNVector3(0, Float(-H / 2 + 0.001), 0)
        phone.addChildNode(portNode)
        for side in [-1.0, 1.0] {
            for i in 0..<6 {
                let hole = SCNCylinder(radius: 0.006, height: 0.004)
                hole.materials = [Self.flat(UIColor(white: 0.02, alpha: 1))]
                let h = SCNNode(geometry: hole)
                h.position = SCNVector3(Float(side * (0.09 + Double(i) * 0.018)), Float(-H / 2 + 0.0005), 0)
                phone.addChildNode(h)
            }
        }
        return phone
    }

    private static func glass(white: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: white, alpha: 1)
        m.roughness.contents = 0.07
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
        cameraNode.position = SCNVector3(0, 0, Float(4.4 / zoom))
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

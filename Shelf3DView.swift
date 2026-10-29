import SwiftUI
import PhotosUI
import SceneKit
import UIKit

// MARK: - La collection en 3D

/// Tous tes albums en CD ou en cassette, en vrai volume : fais-les défiler, touche-les, fais-les tourner.
struct ShelfView: View {
    /// La Collection reste chargée en permanence (cachée) : l'afficher est instantané.
    var visible = true
    var onClose: () -> Void = {}
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(AppSettings.self) private var settings
    @State private var motion = MotionTilt()
    @State private var focusedIndex = 0
    @State private var inspected: AlbumInfo?
    @State private var startIndex: Int?
    // État de l'album en main (gardé ici pour que la vue 3D reste chargée en permanence).
    @State private var discOut = false
    @State private var isBack = false
    @State private var flipToken = 0
    @State private var resetToken = 0
    @State private var stickerAlbum: AlbumInfo?
    /// Sous-section de la Collection : albums (CD), bandes-son de jeux, ou vinyles.
    @State private var section = 0
    /// Vinyle en main : dans sa pochette, ou sorti.
    @State private var vinylStage: VinylStage = .jacket
    @State private var gatefoldOpen = false

    /// Ouverture et fermeture : un ressort court, comme les transitions d'iOS.
    private static let quick = Animation.smooth(duration: 0.38)

    var body: some View {
        let _ = library.artworkRevision
        let albums = section == 1 ? library.gameAlbums : (section == 2 ? library.vinylAlbums : library.exposedAlbums)
        let focused = albums.indices.contains(focusedIndex) ? albums[focusedIndex] : albums.first
        // La vue « en main » est déjà prête avec l'album au centre : l'ouverture est instantanée.
        let handAlbum = inspected ?? focused
        let isOpen = inspected != nil && visible
        ZStack {
            Color(red: 0.03, green: 0.03, blue: 0.04).ignoresSafeArea()

            if albums.isEmpty {
                emptyState
            } else {
                ShelfSceneView(albums: albums, startIndex: startIndex ?? initialIndex(albums), motion: motion, paused: isOpen || !visible,
                               onFocus: { focusedIndex = $0 },
                               onOpen: { i in open(albums[i]) },
                               onLongPress: { i in stickerAlbum = albums[i] })
                    .ignoresSafeArea()
                    // L'étagère recule légèrement quand tu prends un album en main.
                    .scaleEffect(isOpen ? 0.97 : 1)
                    .opacity(isOpen ? 0 : 1)
                    .allowsHitTesting(!isOpen)
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if let focused { caption(focused) }
            }
            .padding(.bottom, 30)
            .opacity(isOpen ? 0 : 1)
            .allowsHitTesting(!isOpen)

            if let handAlbum {
                let format = library.format(of: handAlbum.id, default: settings.shelfFormat)
                let playing = isPlaying(handAlbum)
                RadialGradient(colors: [library.palette(for: handAlbum.cover)[1].opacity(0.35), .clear],
                               center: UnitPoint(x: 0.5, y: 0.42), startRadius: 10, endRadius: 380)
                    .ignoresSafeArea()
                    .opacity(isOpen ? 1 : 0)
                    .allowsHitTesting(false)

                InspectorSceneView(album: handAlbum, format: format, badges: library.badges(for: handAlbum),
                                   motion: motion, active: isOpen, discOut: discOut,
                                   spinning: playing && player.isPlaying,
                                   vinylStage: vinylStage, gatefoldOpen: gatefoldOpen,
                                   flipToken: flipToken, resetToken: resetToken,
                                   onBackChange: { isBack = $0 })
                    .id("inspector")
                    .ignoresSafeArea()
                    .opacity(isOpen ? 1 : 0)
                    .allowsHitTesting(isOpen)

                if let inspected {
                    ShelfInspector(album: inspected, format: format, game: library.gameName(inspected.id),
                                   isBack: isBack, discOut: $discOut,
                                   vinylStage: $vinylStage, gatefoldOpen: $gatefoldOpen,
                                   playingThisAlbum: playing,
                                   onFlip: {
                                       // Directement sur la scène : la réaction est immédiate.
                                       InspectorSceneController.shared?.flip()
                                   },
                                   onDisc: { out in
                                       if let c = InspectorSceneController.shared {
                                           if out { c.ensureDisc() }
                                           c.node?.setDiscOut(out)
                                       }
                                   },
                                   onStickers: { stickerAlbum = inspected },
                                   onFormat: { newValue in
                                       discOut = false
                                       resetToken += 1
                                       library.setFormat(newValue, for: inspected.id)
                                   },
                                   onClose: close)
                        .transition(.opacity)
                        .zIndex(2)
                }
            }
        }
        .foregroundStyle(.white)
        .sheet(item: $stickerAlbum) { album in
            StickerPicker(album: album)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .animation(Self.quick, value: isOpen)
        .sensoryFeedback(trigger: discOut) { _, _ in settings.haptics ? .impact(weight: .medium) : nil }
        .sensoryFeedback(trigger: vinylStage) { _, _ in settings.haptics ? .impact(weight: .medium) : nil }
        .sensoryFeedback(trigger: isBack) { _, _ in settings.haptics && isOpen ? .impact(weight: .light) : nil }
        .onAppear {
            if visible { motion.start() }
            if startIndex == nil {
                let i = initialIndex(albums)
                focusedIndex = i
                startIndex = i
            }
        }
        .onChange(of: visible) { _, shown in
            if shown {
                motion.start()
                // On se replace sur l'album en cours d'écoute.
                let i = initialIndex(library.exposedAlbums)
                if section == 0 && i != focusedIndex {
                    ShelfSceneController.shared?.jump(to: i)
                    focusedIndex = i
                }
            } else {
                motion.stop()
                close()
            }
        }
        .onChange(of: section) { _, _ in
            close()
            focusedIndex = 0
            ShelfSceneController.shared?.jump(to: 0)
        }
        .onDisappear { motion.stop() }
        .statusBarHidden(visible)
    }

    @ViewBuilder private var emptyState: some View {
        if section == 2 {
            ContentUnavailableView("Aucun vinyle", systemImage: "record.circle",
                                   description: Text("Dans la Bibliothèque, touche « Choisir les albums » puis « Vinyles » pour remplir ton bac."))
        } else if section == 1 {
            ContentUnavailableView("Aucune bande-son", systemImage: "gamecontroller",
                                   description: Text("Dans « Modifier les infos » d’un morceau, choisis un ou plusieurs jeux (FIFA 17, FC 24…). Leurs bandes-son apparaîtront ici en boîtiers PS5."))
        } else {
            ContentUnavailableView("Aucun album exposé", systemImage: "opticaldisc",
                                   description: Text("Dans la Bibliothèque, touche « Choisir les albums » pour ranger des albums dans ta Collection."))
        }
    }

    /// La Collection s'ouvre sur l'album en cours d'écoute.
    private func initialIndex(_ albums: [AlbumInfo]) -> Int {
        let playingAlbum = player.currentID.flatMap { library.track($0) }?.albumKey
        return albums.firstIndex { $0.id == playingAlbum } ?? 0
    }

    private func isPlaying(_ album: AlbumInfo) -> Bool {
        guard let id = player.currentID else { return false }
        return album.tracks.contains { $0.id == id }
    }

    private func open(_ album: AlbumInfo) {
        vinylStage = .jacket
        gatefoldOpen = false
        discOut = false
        isBack = false
        inspected = album
    }

    private func close() {
        vinylStage = .jacket
        gatefoldOpen = false
        discOut = false
        inspected = nil
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Collection").font(.largeTitle.bold())
                SectionSwitch(section: $section,
                              albums: library.exposedAlbums.count,
                              games: library.gameAlbums.count,
                              vinyls: library.vinylAlbums.count)
            }
            Spacer()
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .frame(width: 40, height: 40)
                    .glassCircle()
            }
            .accessibilityLabel("Fermer")
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
    }

    private func caption(_ album: AlbumInfo) -> some View {
        let badges = library.badges(for: album)
        return VStack(spacing: 14) {
            // Superposés pendant le fondu (l'ancien titre ne pousse jamais le nouveau).
            ZStack {
            VStack(spacing: 4) {
                Text(album.title)
                    .font(.title2.bold())
                    .lineLimit(1)
                Text([album.artist, album.year > 0 ? "\(album.year)" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                let custom = library.customStickers(for: album.id)
                if !badges.isEmpty || !custom.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(badges) { HoloBadge(badge: $0, light: -0.3, scale: 1.25, showsText: true) }
                        ForEach(custom) { CustomStickerBadge(sticker: $0, size: 30) }
                    }
                    .padding(.top, 6)
                }
            }
            // Le titre change en fondu rapide : l'ancien part tout de suite, le nouveau arrive en glissant à peine.
            .id(album.id)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 6)).animation(.smooth(duration: 0.28).delay(0.06)),
                removal: .opacity.animation(.easeOut(duration: 0.1))))
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                Button { player.play(ids: album.tracks.map(\.id), shuffled: false) } label: {
                    Label("Lire", systemImage: "play.fill")
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .contentShape(Capsule())
                        .glassCapsule()
                }
                Button { open(album) } label: {
                    Label("Prendre en main", systemImage: "hand.point.up.left.fill")
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .contentShape(Capsule())
                        .glassCapsule()
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(PressStyle(circle: false))
        }
        .padding(.horizontal, 20)
        .animation(.smooth(duration: 0.28), value: album.id)
    }
}

// MARK: - Carrousel 3D (SceneKit)

struct ShelfSceneView: UIViewRepresentable {
    let albums: [AlbumInfo]
    let startIndex: Int
    let motion: MotionTilt
    var paused = false
    var onFocus: (Int) -> Void
    var onOpen: (Int) -> Void
    var onLongPress: (Int) -> Void = { _ in }
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings

    func makeCoordinator() -> ShelfSceneController {
        ShelfSceneController.obtain(builder: AlbumNodeBuilder(library: library, settings: settings), start: startIndex)
    }

    func makeUIView(context: Context) -> SCNView {
        let c = context.coordinator
        c.motion = motion
        c.onFocus = onFocus
        c.onOpen = onOpen
        c.onLongPress = onLongPress
        c.update(albums: albums, library: library, settings: settings)
        c.start()
        c.setPaused(paused)
        return c.view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let c = context.coordinator
        c.onFocus = onFocus
        c.onOpen = onOpen
        c.onLongPress = onLongPress
        c.update(albums: albums, library: library, settings: settings)
        c.setPaused(paused)
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: ShelfSceneController) {
        coordinator.stop()
        coordinator.onFocus = { _ in }
        coordinator.onOpen = { _ in }
        coordinator.onLongPress = { _ in }
    }
}

@MainActor
final class ShelfSceneController: NSObject, UIGestureRecognizerDelegate {
    /// Un seul carrousel pour toute l'app, gardé en mémoire : rouvrir la Collection est instantané.
    static var shared: ShelfSceneController?

    static func obtain(builder: AlbumNodeBuilder, start: Int) -> ShelfSceneController {
        if let s = shared {
            s.builder = builder
            s.jump(to: start)
            return s
        }
        let s = ShelfSceneController(builder: builder, start: start)
        shared = s
        return s
    }

    /// Prépare la Collection en arrière-plan, peu après le lancement de l'app.
    static func warmUp(library: Library, settings: AppSettings, start: Int) async {
        let albums = library.exposedAlbums
        guard !albums.isEmpty else { return }
        let builder = AlbumNodeBuilder(library: library, settings: settings)
        let c = obtain(builder: builder, start: start)
        c.update(albums: albums, library: library, settings: settings)
        let order = albums.indices.sorted { abs($0 - start) < abs($1 - start) }
        // Seulement les plus proches, espacés : le reste se fabrique au besoin, à l'arrêt du carrousel.
        for i in order.prefix(14) {
            _ = c.node(at: i, force: true)
            try? await Task.sleep(for: .milliseconds(90))
        }
        // Les boîtiers de jeux aussi, pour que l'onglet Jeux s'ouvre sans attendre.
        // Ils sont fabriqués cachés, sans jamais changer la liste affichée (plus de « flash » à l'ouverture).
        for game in library.gameAlbums.prefix(6) {
            let format = library.format(of: game.id, default: settings.shelfFormat)
            c.prebuild(game, format: format, badges: library.badges(for: game))
            try? await Task.sleep(for: .milliseconds(40))
        }
        // Quelques vinyles aussi (fabriqués cachés).
        for vinyl in library.vinylAlbums.prefix(3) {
            c.prebuild(vinyl, format: .vinyl, badges: library.badges(for: vinyl))
            try? await Task.sleep(for: .milliseconds(60))
        }
        c.layout()
        c.view.prepare([c.scene], completionHandler: nil)
        // La vue « en main » aussi (en haute définition).
        var hiResBuilder = builder
        hiResBuilder.hiRes = true
        let inspector = InspectorSceneController.obtain()
        inspector.show(album: albums[start.clamped(0, albums.count - 1)],
                       format: library.format(of: albums[start.clamped(0, albums.count - 1)].id, default: settings.shelfFormat),
                       badges: library.badges(for: albums[start.clamped(0, albums.count - 1)]),
                       builder: hiResBuilder, animated: false)
        inspector.view.prepare([inspector.scene], completionHandler: nil)
    }

    let view = SCNView()
    let scene = SCNScene()
    var builder: AlbumNodeBuilder
    var motion: MotionTilt?
    var onFocus: (Int) -> Void = { _ in }
    var onOpen: (Int) -> Void = { _ in }
    var onLongPress: (Int) -> Void = { _ in }
    private var lastTime: CFTimeInterval = 0

    private var albums: [AlbumInfo] = []
    private var formats: [AlbumFormat] = []
    private var badges: [[AlbumBadge]] = []
    private var nodes: [String: AlbumNode] = [:]
    private var pos: Double
    private var target: Double
    private var vel: Double = 0
    private var dragging = false
    private var dragStart: Double = 0
    private var lastFocus = -1
    private var link: CADisplayLink?
    private let haptic = UISelectionFeedbackGenerator()
    private let cameraNode = SCNNode()
    private var lastSpotAlbum = ""
    private var pausedState = false

    /// Mise en page : Cover Flow (CD, jeux), bac à feuilleter ou étagère murale (vinyles).
    enum LayoutMode { case flow, crate, wall }
    private var mode: LayoutMode = .flow
    private var crateNode: SCNNode?
    private var ledgeNode: SCNNode?

    private func setMode(_ m: LayoutMode) {
        guard m != mode else { return }
        mode = m
        if m == .crate && crateNode == nil {
            let crate = VinylFurniture.crate(innerWidth: 1.62)
            scene.rootNode.addChildNode(crate)
            crateNode = crate
        }
        if m == .wall && ledgeNode == nil {
            let ledge = VinylFurniture.ledge()
            scene.rootNode.addChildNode(ledge)
            ledgeNode = ledge
        }
        crateNode?.isHidden = m != .crate
        ledgeNode?.isHidden = m != .wall
        // Le brouillard du fond recule avec la caméra (sinon les pochettes s'assombrissent).
        switch m {
        case .flow:
            cameraNode.position = SCNVector3(0, 0.95, 8.6)
            cameraNode.look(at: SCNVector3(0, 0.16, 0))
            scene.fogStartDistance = 8
            scene.fogEndDistance = 15
        case .crate:
            // Vu de haut et de loin, comme debout devant un bac chez le disquaire : tout le bac
            // et la pochette du dessus sont visibles en entier.
            cameraNode.position = SCNVector3(0, 4.6, 10.6)
            cameraNode.look(at: SCNVector3(0, 0.95, -0.1))
            scene.fogStartDistance = 13
            scene.fogEndDistance = 22
        case .wall:
            cameraNode.position = SCNVector3(0, 1.2, 10.2)
            cameraNode.look(at: SCNVector3(0, 0.8, 0))
            scene.fogStartDistance = 12
            scene.fogEndDistance = 20
        }
    }

    func jump(to index: Int) {
        let i = albums.isEmpty ? index : min(max(0, index), albums.count - 1)
        pos = Double(i)
        target = Double(i)
        vel = 0
        lastFocus = -1
    }

    init(builder: AlbumNodeBuilder, start: Int) {
        self.builder = builder
        pos = Double(start)
        target = Double(start)
        super.init()
        Studio.addLights(to: scene, withFloor: true)

        let camera = SCNCamera()
        camera.fieldOfView = 30
        camera.zNear = 0.1
        cameraNode.camera = camera
        // Caméra presque à hauteur des pochettes, comme Cover Flow : l'objet est grand, centré,
        // et son reflet occupe le sol en dessous.
        cameraNode.position = SCNVector3(0, 0.95, 8.6)
        cameraNode.look(at: SCNVector3(0, 0.16, 0))
        scene.rootNode.addChildNode(cameraNode)

        view.scene = scene
        view.pointOfView = cameraNode
        view.configureForShelf()

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let long = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        long.minimumPressDuration = 0.45
        for g in [pan, tap, long] as [UIGestureRecognizer] {
            g.delegate = self
            g.cancelsTouchesInView = false
            view.addGestureRecognizer(g)
        }
        setPaused(true)
    }

    /// Les gestes 3D ne prennent jamais le doigt posé sur un bouton (haut et bas de l'écran).
    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        MainActor.assumeIsolated {
            let p = touch.location(in: view)
            let h = view.bounds.height
            if p.y < 120 || p.y > h - 200 { return false }
            if g is UITapGestureRecognizer || g is UILongPressGestureRecognizer {
                return !view.hitTest(p, options: nil).isEmpty
            }
            return true
        }
    }

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        l.isPaused = pausedState
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
        setPaused(true)
    }

    /// Caché (album en main, ou Collection fermée) : le carrousel ne se redessine plus et ne capte plus les touchers.
    func setPaused(_ paused: Bool) {
        view.isUserInteractionEnabled = !paused
        guard paused != pausedState else { return }
        pausedState = paused
        lastTime = 0
        link?.isPaused = paused
        view.rendersContinuously = !paused
        view.isPlaying = !paused
    }

    func update(albums newAlbums: [AlbumInfo], library: Library, settings: AppSettings) {
        builder = AlbumNodeBuilder(library: library, settings: settings)
        let vinyls = newAlbums.first.map { VinylCatalog.isVinyl($0.id) } ?? false
        setMode(vinyls ? (settings.vinylStorage == .crate ? .crate : .wall) : .flow)
        albums = newAlbums
        formats = newAlbums.map { library.format(of: $0.id, default: settings.shelfFormat) }
        badges = newAlbums.map { library.badges(for: $0) }
        let ids = Set(newAlbums.map(\.id))
        for (id, node) in nodes where !ids.contains(id) {
            node.root.isHidden = true
        }
        // Blister : affiché ou retiré selon l'album (sans reconstruire le boîtier).
        for album in newAlbums {
            nodes[album.id]?.setWrapVisible(settings.shrinkWrap && library.isSealed(album.id))
        }
        // Un format ou une pochette qui change : le modèle est reconstruit.
        for (i, album) in albums.enumerated() {
            if let node = nodes[album.id], node.signature != builder.signature(album, formats[i], badges[i]) {
                node.root.removeFromParentNode()
                nodes[album.id] = nil
            }
        }
        let maxIndex = Double(max(0, albums.count - 1))
        target = min(max(0, target), maxIndex)
        pos = min(max(-0.5, pos), maxIndex + 0.5)
        // La mise en page se fait à la prochaine image (jamais pendant la mise à jour de SwiftUI).
    }

    private var builtThisFrame = false

    /// Le modèle d'un album s'il existe déjà ; sinon il est fabriqué (au plus un par image).
    fileprivate func node(at i: Int, force: Bool = false) -> AlbumNode? {
        let album = albums[i]
        if let n = nodes[album.id] { return n }
        // Un modèle neuf n'est fabriqué qu'à l'arrêt (jamais pendant que tu fais défiler) : zéro à-coup.
        guard force || (!builtThisFrame && !dragging && abs(vel) < 0.05) else { return nil }
        builtThisFrame = true
        let n = makeNode(album, format: formats[i], badges: badges[i])
        // Apparition en fondu seulement si l'objet est déjà à l'écran.
        n.root.opacity = 0
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.35
        n.root.opacity = 1
        SCNTransaction.commit()
        return n
    }

    /// Fabrique un objet en avance, caché, sans toucher à ce qui est affiché.
    func prebuild(_ album: AlbumInfo, format: AlbumFormat, badges: [AlbumBadge]) {
        if let n = nodes[album.id], n.signature == builder.signature(album, format, badges) { return }
        nodes[album.id]?.root.removeFromParentNode()
        let n = makeNode(album, format: format, badges: badges)
        n.root.isHidden = true
    }

    private func makeNode(_ album: AlbumInfo, format: AlbumFormat, badges: [AlbumBadge]) -> AlbumNode {
        let n = builder.make(album, format: format, badges: badges, extras: false)
        if format == .vinyl {
            // Les vinyles sont posés dans le bac ou sur l'étagère : ni ombre au sol, ni reflet.
            scene.rootNode.addChildNode(n.root)
            nodes[album.id] = n
            return n
        }
        // Ombre douce posée au sol.
        let w = CGFloat(n.shownSize.x)
        let shadow = SCNPlane(width: w * 1.25, height: w * 0.45)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = AlbumNodeBuilder.contactShadow
        m.writesToDepthBuffer = false
        shadow.materials = [m]
        let shadowNode = SCNNode(geometry: shadow)
        shadowNode.eulerAngles.x = -.pi / 2
        shadowNode.position = SCNVector3(0, -n.shownSize.y / 2 + 0.004, 0.05)
        n.root.addChildNode(shadowNode)
        if let r = n.reflection {
            // Reflet sur le sol brillant : une simple image retournée, préparée à l'avance (zéro calcul en plus).
            let fit = CGFloat(n.fit)
            let plane = SCNPlane(width: r.width * fit, height: r.height * fit)
            let rm = SCNMaterial()
            rm.lightingModel = .constant
            rm.diffuse.contents = r.image
            rm.blendMode = .alpha
            rm.writesToDepthBuffer = false
            plane.materials = [rm]
            let reflect = SCNNode(geometry: plane)
            let bottom = -n.shownSize.y / 2
            reflect.position = SCNVector3(r.x * n.fit, bottom - Float(r.height * fit) / 2 - 0.006, r.z * n.fit)
            n.root.addChildNode(reflect)
        }
        scene.rootNode.addChildNode(n.root)
        nodes[album.id] = n
        return n
    }

    @objc private func tick(_ link: CADisplayLink) {
        builtThisFrame = false
        // Physique basée sur le temps réel : même vitesse et même douceur à 60 ou 120 images/s,
        // et aucune saccade si une image est un peu en retard.
        let now = link.targetTimestamp
        let dt = lastTime == 0 ? 1.0 / 120 : min(max(now - lastTime, 1.0 / 240), 1.0 / 30)
        lastTime = now
        if !dragging {
            // Ressort amorti façon UIKit : le CD glisse puis se pose, sans rebond.
            let k = 230.0
            let damping = 2 * k.squareRoot()
            vel += (k * (target - pos) - damping * vel) * dt
            pos += vel * dt
            if abs(vel) < 0.003 && abs(target - pos) < 0.0005 { pos = target; vel = 0 }
        }
        layout()
    }

    fileprivate func layout() {
        guard !albums.isEmpty else { return }
        let tiltX = motion?.x ?? 0
        let tiltY = motion?.y ?? 0
        let focus = Int((pos).rounded()).clamped(0, albums.count - 1)
        for i in albums.indices {
            let d = Double(i) - pos
            let ad = abs(d)
            let album = albums[i]
            // Dans le bac, on voit bien plus de pochettes derrière celle du dessus.
            let hidden = mode == .crate ? (d > 9 || d < -3.5) : ad > 4.5
            if hidden {
                nodes[album.id]?.root.isHidden = true
                continue
            }
            guard let n = node(at: i, force: ad < 0.6) else { continue }
            n.root.isHidden = false
            switch mode {
            case .flow: coverFlow(n, d: d, ad: ad, isFocus: i == focus && ad < 0.5, tiltX: tiltX, tiltY: tiltY)
            case .crate: crate(n, d: d, tiltX: tiltX, tiltY: tiltY)
            case .wall: wall(n, d: d, ad: ad, tiltX: tiltX, tiltY: tiltY)
            }
        }
        if focus != lastFocus {
            lastFocus = focus
            haptic.selectionChanged()
            onFocus(focus)
            updateSpot(for: albums[focus])
        }
    }

    /// Mise en page façon Cover Flow, pour les CD comme pour les jaquettes : l'objet du centre est de face
    /// et avance vers toi ; les autres se tournent vers lui et s'empilent serrés de chaque côté.
    /// Tout est continu (position, vitesse, angle) : aucun à-coup en passant d'un objet à l'autre.
    private func coverFlow(_ n: AlbumNode, d: Double, ad: Double, isFocus: Bool, tiltX: Double, tiltY: Double) {
        let s = d < 0 ? -1.0 : 1.0
        let e = min(ad, 1)
        let ease = e * e * (3 - 2 * e)
        let game = n.format == .game
        let gap = game ? 0.24 : 0.27
        let x = d * gap + s * ease * (game ? 0.7 : 0.66)
        let z = (1 - ease) * 0.22 - ease * 0.8 - max(0, ad - 1) * 0.05
        let rotY = -s * ease * 1.12
        let h = Double(n.shownSize.y)
        n.root.position = SCNVector3(Float(x), Float(h / 2 + 0.001), Float(z))
        n.root.scale = SCNVector3(1, 1, 1)
        // Les derniers s'effacent doucement au lieu de disparaître d'un coup.
        let fade = ad > 3 ? max(0, 1 - (ad - 3) / 1.5) : 1
        if abs(Double(n.root.opacity) - fade) > 0.01, n.root.action(forKey: "appear") == nil { n.root.opacity = CGFloat(fade) }
        // L'inclinaison de l'iPhone ne joue que sur l'objet du centre, en douceur (pas de saut).
        let w = 1 - ease
        let tx = -tiltY * 0.05 * w
        let ty = rotY + tiltX * 0.1 * w
        n.root.eulerAngles = SCNVector3(Float(tx), Float(ty), 0)
    }

    /// Bac à feuilleter : les pochettes sont debout, serrées ; celle du dessus est soulevée vers toi,
    /// celles déjà feuilletées sont penchées vers l'avant, appuyées sur le bord du bac.
    private func crate(_ n: AlbumNode, d: Double, tiltX: Double, tiltY: Double) {
        let h = Double(n.shownSize.y)
        // Position du bas de la pochette et inclinaison (rotation autour de l'axe horizontal).
        func pose(_ d: Double) -> (y: Double, z: Double, rx: Double) {
            if d >= 1 { return (0.06, -0.16 - (d - 1) * 0.105, -0.16) }
            if d <= -1 { return (0.06, 0.55 + (d + 1) * 0.045, 0.66) }
            // Celle du dessus est bien soulevée : on la voit en entier au-dessus des autres.
            let focus = (y: 0.82, z: 0.22, rx: -0.06)
            let other = d > 0 ? pose(1) : pose(-1)
            let e = abs(d)
            let k = e * e * (3 - 2 * e)
            return (focus.y + (other.y - focus.y) * k, focus.z + (other.z - focus.z) * k, focus.rx + (other.rx - focus.rx) * k)
        }
        let p = pose(d)
        let y = p.y + cos(p.rx) * h / 2
        let z = p.z + sin(p.rx) * h / 2
        n.root.position = SCNVector3(0, Float(y), Float(z))
        n.root.scale = SCNVector3(1, 1, 1)
        let w = max(0, 1 - abs(d))
        n.root.eulerAngles = SCNVector3(Float(p.rx - tiltY * 0.04 * w), Float(tiltX * 0.08 * w), 0)
        let fade = d > 7.5 ? max(0, 1 - (d - 7.5) / 1.5) : 1
        if abs(Double(n.root.opacity) - fade) > 0.01 { n.root.opacity = CGFloat(fade) }
    }

    /// Étagère murale : les pochettes posées de face côte à côte ; celle du centre avance un peu.
    private func wall(_ n: AlbumNode, d: Double, ad: Double, tiltX: Double, tiltY: Double) {
        let w = Double(n.shownSize.x), h = Double(n.shownSize.y)
        let e = min(ad, 1)
        let ease = e * e * (3 - 2 * e)
        let x = d * (w + 0.14)
        let z = (1 - ease) * 0.3
        let y = h / 2 + 0.06 + (1 - ease) * 0.06
        n.root.position = SCNVector3(Float(x), Float(y), Float(z))
        n.root.scale = SCNVector3(1, 1, 1)
        let k = 1 - ease
        n.root.eulerAngles = SCNVector3(Float(-0.05 - tiltY * 0.05 * k), Float(tiltX * 0.1 * k), 0)
        let fade = ad > 3 ? max(0, 1 - (ad - 3) / 1.5) : 1
        if abs(Double(n.root.opacity) - fade) > 0.01 { n.root.opacity = CGFloat(fade) }
    }

    private func updateSpot(for album: AlbumInfo) {
        guard album.id != lastSpotAlbum, let spot = scene.rootNode.childNode(withName: "spot", recursively: false)?.light else { return }
        lastSpotAlbum = album.id
        let color = UIColor(builder.library.palette(for: album.cover)[1])
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.8
        spot.color = color
        SCNTransaction.commit()
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        // Dans le bac, on feuillette de haut en bas (glisser vers le bas : pochette suivante).
        let vertical = mode == .crate
        let width = max(view.bounds.width, 1)
        let unit = vertical ? Double(max(view.bounds.height, 1)) * 0.2 : Double(width) * 0.42
        let moved = vertical ? Double(g.translation(in: view).y) : -Double(g.translation(in: view).x)
        let speed = vertical ? Double(g.velocity(in: view).y) : -Double(g.velocity(in: view).x)
        switch g.state {
        case .began:
            dragging = true
            dragStart = pos
            vel = 0
        case .changed:
            let raw = dragStart + moved / unit
            let maxIndex = Double(albums.count - 1)
            // Résistance élastique aux extrémités.
            if raw < 0 { pos = -(1 - 1 / (1 + -raw * 0.55)) * 1.1 }
            else if raw > maxIndex { pos = maxIndex + (1 - 1 / (1 + (raw - maxIndex) * 0.55)) * 1.1 }
            else { pos = raw }
        default:
            dragging = false
            // L'élan du doigt est conservé : le carrousel continue puis se pose en douceur.
            let v = speed / unit
            // Projection comme UIScrollView : un petit coup avance d'un album, un grand lancer en fait défiler plusieurs.
            let projected = pos + v * 0.3
            target = projected.rounded().clamped(0, Double(albums.count - 1))
            vel = max(-18, min(18, v))
        }
    }

    /// L'album sous le doigt.
    private func albumIndex(at point: CGPoint) -> Int? {
        let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
        guard let hit = hits.first?.node else { return nil }
        for (i, album) in albums.enumerated() {
            guard let n = nodes[album.id] else { continue }
            var cur: SCNNode? = hit
            while let c = cur, c !== n.root { cur = c.parent }
            if cur != nil { return i }
        }
        return nil
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard let i = albumIndex(at: g.location(in: view)) else { return }
        if i == Int(target.rounded()) { onOpen(i) } else { target = Double(i) }
    }

    /// Appui long : choisir les stickers holographiques de cet album.
    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let i = albumIndex(at: g.location(in: view)) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        target = Double(i)
        onLongPress(i)
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}

// MARK: - Prendre un album en main

struct ShelfInspector: View {
    let album: AlbumInfo
    let format: AlbumFormat
    /// Nom du jeu quand c'est une bande-son (boîtier PS5).
    var game: String?
    let isBack: Bool
    @Binding var discOut: Bool
    @Binding var vinylStage: VinylStage
    @Binding var gatefoldOpen: Bool
    let playingThisAlbum: Bool
    var onFlip: () -> Void
    var onDisc: (Bool) -> Void
    var onStickers: () -> Void
    var onFormat: (AlbumFormat) -> Void
    var onClose: () -> Void
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var photoItem: PhotosPickerItem?
    @State private var cropping: CropSource?
    @State private var customizing = false
    @State private var unwrapTick = 0
    /// Face visible du vinyle sorti.
    @State private var shownSide = 0

    /// CD ou vinyle encore sous blister : il faut le déballer avant de sortir le disque.
    private var sealed: Bool { (format == .cd || format == .vinyl) && settings.shrinkWrap && library.isSealed(album.id) }

    private var vinylSides: [VinylSide] {
        VinylLayout.sides(album, discs: VinylLayout.discCount(album, library.vinylOptions(album.id)))
    }

    /// Face suivante du disque sorti (A → B → C → D → A), en sautant les faces vides.
    private var nextSide: Int? {
        let sides = vinylSides
        guard sides.count > 1 else { return nil }
        for k in 1..<sides.count {
            let i = (shownSide + k) % sides.count
            if !sides[i].tracks.isEmpty { return i }
        }
        return nil
    }

    /// Lance une face depuis son premier morceau.
    private func playSide(_ i: Int) {
        guard vinylSides.indices.contains(i), let first = vinylSides[i].tracks.first else { return }
        player.play(ids: album.tracks.map(\.id), startAt: first.id, shuffled: false)
    }

    @ViewBuilder private var vinylButtons: some View {
        let spinning = playingThisAlbum && player.isPlaying
        switch vinylStage {
        case .jacket:
            inspectorButton(isBack ? "Face" : "Dos", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", action: onFlip)
            inspectorButton("Sortir le vinyle", symbol: "record.circle") {
                gatefoldOpen = false
                vinylStage = .out
            }
            if library.vinylOptions(album.id).gatefold {
                inspectorButton(gatefoldOpen ? "Fermer" : "Ouvrir", symbol: gatefoldOpen ? "book.closed" : "book") {
                    gatefoldOpen.toggle()
                }
            } else {
                inspectorButton(spinning ? "Pause" : "Lire", symbol: spinning ? "pause.fill" : "play.fill") {
                    if playingThisAlbum { player.togglePlay() } else { playAlbum() }
                }
            }
            inspectorButton("Stickers", symbol: "seal.fill", action: onStickers)
        case .out:
            inspectorButton("Ranger", symbol: "arrow.down.to.line") {
                shownSide = 0
                InspectorSceneController.shared?.node?.flipDisc(toSide: 0)
                vinylStage = .jacket
            }
            if let next = nextSide {
                // Retourne le disque pour voir l'autre face (son étiquette et ses sillons).
                inspectorButton("Face " + vinylSides[next].letter, symbol: "arrow.triangle.2.circlepath") {
                    shownSide = next
                    InspectorSceneController.shared?.node?.flipDisc(toSide: next)
                }
            }
            inspectorButton(spinning ? "Pause" : "Lire", symbol: spinning ? "pause.fill" : "play.fill") {
                if playingThisAlbum { player.togglePlay() } else { playSide(shownSide) }
            }
            inspectorButton("Stickers", symbol: "seal.fill", action: onStickers)
        }
    }

    var body: some View {
        let spinning = playingThisAlbum && player.isPlaying
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                if let game {
                    // Bande-son : console du boîtier (PS3, PS4, PS5).
                    PlatformSwitch(platform: library.platform(of: game)) { library.setPlatform($0, for: game) }
                }
                // Personnaliser : jaquette, dos, tranche et disque (le disque seulement pour un CD).
                Button {
                    customizing = true
                } label: {
                    Label("Personnaliser", systemImage: "paintbrush.pointed.fill")
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                        .glassCircle()
                }
                .buttonStyle(PressStyle(circle: false))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.bold))
                        .frame(width: 40, height: 40)
                        .glassCircle()
                }
                .accessibilityLabel("Reposer")
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)

            Spacer(minLength: 0)
                .allowsHitTesting(false)

            VStack(spacing: 4) {
                Text(album.title).font(.title2.bold()).lineLimit(1)
                Text(album.artist).font(.headline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            .allowsHitTesting(false)

            Text(format == .vinyl && vinylStage == .out
                 ? "« Face » retourne le disque · « Lire » joue la face visible · glisse pour tourner"
                 : "Glisse pour tourner · touche pour retourner · pince pour zoomer · touche deux fois pour remettre droit · appui long sur un album pour ses stickers")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .allowsHitTesting(false)

            HStack(spacing: 10) {
                if format == .vinyl && !sealed {
                    vinylButtons
                } else {
                inspectorButton(format == .cassette ? (isBack ? "Face A" : "Face B") : (isBack ? "Face" : "Dos"),
                                symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", action: onFlip)
                if sealed {
                    inspectorButton("Déballer", symbol: "scissors") {
                        unwrapTick += 1
                        if let node = InspectorSceneController.shared?.node, node.isWrapped {
                            node.unwrap()
                        } else {
                            library.setSealed(album.id, false)
                        }
                    }
                    .transition(.blurReplace)
                } else if format == .cd || format == .game {
                    inspectorButton(discTitle, symbol: discSymbol) {
                        let out = !discOut
                        onDisc(out)
                        discOut = out
                        if out && !playingThisAlbum { playAlbum() }
                    }
                }
                inspectorButton(spinning ? "Pause" : "Lire", symbol: spinning ? "pause.fill" : "play.fill") {
                    if playingThisAlbum { player.togglePlay() } else { playAlbum() }
                }
                inspectorButton("Stickers", symbol: "seal.fill", action: onStickers)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 26)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: sealed)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: vinylStage)
        }
        .sensoryFeedback(trigger: unwrapTick) { _, _ in settings.haptics ? .impact(flexibility: .soft, intensity: 0.8) : nil }
        .onChange(of: photoItem) { _, item in loadCover(item) }
        .sheet(isPresented: $customizing) {
            // Feuille à mi-hauteur : le boîtier reste visible au-dessus et se met à jour en direct.
            CaseCustomizer(album: album, game: game)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        }
    }

    private var discTitle: String {
        if format == .game { return discOut ? "Refermer" : "Ouvrir" }
        return discOut ? "Ranger le CD" : "Sortir le CD"
    }

    private var discSymbol: String { format == .game ? "gamecontroller" : "opticaldisc" }

    private func loadCover(_ item: PhotosPickerItem?) {
        guard let item, game != nil else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                // On recadre d'abord l'image au format de la jaquette.
                cropping = CropSource(image: img)
            }
            photoItem = nil
        }
    }

    private func inspectorButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .glass(18)
        }
        .buttonStyle(PressStyle(circle: false))
    }

    private func playAlbum() {
        player.play(ids: album.tracks.map(\.id), shuffled: false)
    }
}

struct InspectorSceneView: UIViewRepresentable {
    let album: AlbumInfo
    let format: AlbumFormat
    let badges: [AlbumBadge]
    let motion: MotionTilt
    let active: Bool
    let discOut: Bool
    let spinning: Bool
    var vinylStage: VinylStage = .jacket
    var gatefoldOpen = false
    let flipToken: Int
    let resetToken: Int
    var onBackChange: (Bool) -> Void
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings

    func makeCoordinator() -> InspectorSceneController { InspectorSceneController.obtain() }

    func makeUIView(context: Context) -> SCNView {
        let c = context.coordinator
        c.motion = motion
        c.onBackChange = onBackChange
        c.flipToken = flipToken
        c.resetToken = resetToken
        apply(c)
        return c.view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let c = context.coordinator
        c.onBackChange = onBackChange
        apply(c)
        if flipToken != c.flipToken { c.flipToken = flipToken; c.flip() }
        if resetToken != c.resetToken { c.resetToken = resetToken; c.reset() }
    }

    private func apply(_ c: InspectorSceneController) {
        // En main : textures en haute définition.
        var builder = AlbumNodeBuilder(library: library, settings: settings)
        builder.hiRes = true
        if active {
            c.show(album: album, format: format, badges: badges, builder: builder, animated: true)
        } else {
            // Pendant que tu fais défiler : rien n'est fabriqué. L'album est préparé une fois le carrousel posé.
            c.prepare(album: album, format: format, badges: badges, builder: builder)
        }
        c.setActive(active)
        c.node?.setWrapVisible(settings.shrinkWrap && library.isSealed(album.id))
        if format == .vinyl {
            // Vinyle : dans sa pochette, ou sorti à moitié de sa sous-pochette.
            if active && vinylStage != .jacket { c.ensureDisc() }
            c.node?.setVinylStage(active ? vinylStage : .jacket)
            c.node?.setGatefold(open: active && gatefoldOpen && vinylStage == .jacket)
            return
        }
        if discOut { c.ensureDisc() }
        c.node?.setDiscOut(discOut && active)
        c.node?.setSpinning(active && spinning && (format == .cassette || discOut))
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: InspectorSceneController) {
        coordinator.setActive(false)
        coordinator.stop()
    }
}

@MainActor
final class InspectorSceneController: NSObject, UIGestureRecognizerDelegate {
    /// Ombre floue (dégradé radial sombre).
    static let softShadow: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 256, height: 290)).image { ctx in
            let colors = [UIColor(white: 0, alpha: 0.75).cgColor, UIColor(white: 0, alpha: 0).cgColor] as CFArray
            guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
            let center = CGPoint(x: 128, y: 145)
            ctx.cgContext.drawRadialGradient(grad, startCenter: center, startRadius: 10,
                                             endCenter: center, endRadius: 128, options: [])
        }
    }()

    static var shared: InspectorSceneController?

    static func obtain() -> InspectorSceneController {
        if let s = shared { return s }
        let s = InspectorSceneController()
        shared = s
        return s
    }

    let view = SCNView()
    let scene = SCNScene()
    var motion: MotionTilt?
    var onBackChange: (Bool) -> Void = { _ in }
    var flipToken = 0
    var resetToken = 0
    private(set) var node: AlbumNode?
    private let cameraNode = SCNNode()
    private let holder = SCNNode()
    private var link: CADisplayLink?

    /// Inclinaison de repos : l'objet est légèrement tourné vers toi, comme tenu en main.
    private let restX = -0.1
    private let restY = 0.28

    // Rotation guidée : position, cible, vitesse (ressort).
    private var rx = -0.1, ry = 0.28
    private var tx = -0.1, ty = 0.28
    private var vx = 0.0, vy = 0.0
    private var startX = 0.0, startY = 0.0
    private var dragging = false
    private var zoom = 1.0, zoomTarget = 1.0, pinchStart = 1.0
    private var lastBack = false
    private var active = false
    private var builder: AlbumNodeBuilder?
    private var album: AlbumInfo?
    private var lastTime: CFTimeInterval = 0
    private var zoomV = 0.0
    private var prepareTask: Task<Void, Never>?

    /// Prépare l'album du centre en arrière-plan, seulement quand le carrousel s'est arrêté dessus.
    func prepare(album: AlbumInfo, format: AlbumFormat, badges: [AlbumBadge], builder: AlbumNodeBuilder) {
        guard node?.signature != builder.signature(album, format, badges) else { return }
        prepareTask?.cancel()
        prepareTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled, !self.active else { return }
            self.show(album: album, format: format, badges: badges, builder: builder, animated: false)
        }
    }

    override init() {
        super.init()
        Studio.addLights(to: scene, withFloor: false)
        let camera = SCNCamera()
        camera.fieldOfView = 32
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 6.6)
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(holder)
        holder.position = SCNVector3(0, 0.3, 0)
        holder.eulerAngles = SCNVector3(Float(restX), Float(restY), 0)
        // Ombre douce derrière l'objet tenu en main : il se détache du fond.
        let shadow = SCNPlane(width: 3.0, height: 3.4)
        let shadowMat = SCNMaterial()
        shadowMat.lightingModel = .constant
        shadowMat.diffuse.contents = Self.softShadow
        shadowMat.writesToDepthBuffer = false
        shadow.materials = [shadowMat]
        let shadowNode = SCNNode(geometry: shadow)
        shadowNode.position = SCNVector3(0.08, 0.12, -0.9)
        shadowNode.renderingOrder = -1
        shadowNode.opacity = 0.7
        scene.rootNode.addChildNode(shadowNode)

        view.scene = scene
        view.pointOfView = cameraNode
        view.configureForShelf()
        // Un seul objet à l'écran : on peut lisser les bords davantage.
        view.antialiasingMode = .multisampling4X
        // En veille au départ : la vue se dessine une fois (shaders prêts) puis attend.
        view.rendersContinuously = false
        view.isPlaying = false

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        // Pas d'attente du double toucher : le toucher simple réagit instantanément.
        for g in [pan, pinch, double, single] as [UIGestureRecognizer] {
            g.delegate = self
            g.cancelsTouchesInView = false
            view.addGestureRecognizer(g)
        }
        view.isUserInteractionEnabled = false
    }

    /// Les boutons (Dos, Sortir le CD, Lire…) restent toujours prioritaires sur les gestes 3D.
    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        MainActor.assumeIsolated {
            let p = touch.location(in: view)
            let h = view.bounds.height
            if p.y < 110 || p.y > h - 230 { return false }
            if g is UITapGestureRecognizer {
                return !view.hitTest(p, options: nil).isEmpty
            }
            return true
        }
    }

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        lastTime = 0
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// Allume ou met en veille la vue « en main ». En veille elle ne consomme rien,
    /// mais reste prête : l'ouvrir est instantané.
    func setActive(_ on: Bool) {
        view.isUserInteractionEnabled = on
        guard on != active else { return }
        active = on
        if on {
            sleepTask?.cancel()
            prepareTask?.cancel()
            // On « soulève » l'objet : il grandit, pivote et se pose avec un très léger rebond.
            rx = restX + 0.12; tx = restX
            ry = restY + 0.7; ty = restY
            vx = 0; vy = 0
            zoom = 0.8; zoomTarget = 1; zoomV = 0
            start()
            view.rendersContinuously = true
            view.isPlaying = true
            // Le disque est préparé juste après l'ouverture, sans la ralentir.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, self.active else { return }
                self.ensureDisc()
            }
        } else {
            // On ne fige pas tout de suite : l'objet recule doucement pendant qu'il s'efface,
            // puis se remet en place une fois invisible (plus de zoom brusque en le reposant).
            zoomTarget = 0.86
            tx = restX; ty = (((ty - restY) / (2 * .pi)).rounded()) * 2 * .pi + restY
            sleepTask?.cancel()
            sleepTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, !Task.isCancelled, !self.active else { return }
                self.goToSleep()
            }
        }
    }

    private var sleepTask: Task<Void, Never>?

    private func goToSleep() {
        do {
            stop()
            view.rendersContinuously = false
            view.isPlaying = false
            node?.setSpinning(false)
            node?.settle()
            rx = restX; tx = restX; ry = restY; ty = restY
            vx = 0; vy = 0; zoom = 1; zoomTarget = 1
            holder.eulerAngles = SCNVector3(Float(restX), Float(restY), 0)
            cameraNode.position = SCNVector3(0, 0, 6.6)
            if lastBack {
                lastBack = false
                let report = onBackChange
                Task { @MainActor in report(false) }
            }
        }
    }

    func ensureDisc() {
        guard let node, node.format != .cassette, !node.hasDisc, let builder, let album else { return }
        node.attachDisc(builder.makeDisc(album))
    }

    func show(album: AlbumInfo, format: AlbumFormat, badges: [AlbumBadge], builder: AlbumNodeBuilder, animated: Bool) {
        self.builder = builder
        self.album = album
        let sig = builder.signature(album, format, badges)
        guard node?.signature != sig else { return }
        let old = node
        let fresh = builder.make(album, format: format, badges: badges, extras: false)
        let wasOpen = old?.discOut ?? false
        // Même album reconstruit (sticker, couleur du disque…) : le vinyle reste où il était.
        let oldStage = old?.albumID == album.id ? (old?.vinyl?.stage ?? .jacket) : .jacket
        let oldGatefold = old?.albumID == album.id && (old?.vinyl?.gatefoldOpen ?? false)
        guard animated else {
            old?.root.removeFromParentNode()
            holder.addChildNode(fresh.root)
            node = fresh
            if wasOpen { keepOpen(fresh) }
            keepVinyl(fresh, stage: oldStage, gatefold: oldGatefold)
            return
        }
        fresh.root.opacity = 0
        fresh.root.scale = SCNVector3(0.92, 0.92, 0.92)
        holder.addChildNode(fresh.root)
        node = fresh
        if wasOpen { keepOpen(fresh) }
        keepVinyl(fresh, stage: oldStage, gatefold: oldGatefold)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.3
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
        fresh.root.opacity = 1
        fresh.root.scale = SCNVector3(1, 1, 1)
        old?.root.opacity = 0
        old?.root.scale = SCNVector3(1.05, 1.05, 1.05)
        SCNTransaction.completionBlock = { old?.root.removeFromParentNode() }
        SCNTransaction.commit()
    }

    private func keepVinyl(_ fresh: AlbumNode, stage: VinylStage, gatefold: Bool) {
        guard fresh.vinyl != nil else { return }
        if stage != .jacket {
            ensureDisc()
            fresh.setVinylStage(stage, animated: false)
        } else if gatefold {
            fresh.setGatefold(open: true, animated: false)
        }
    }

    /// Un modèle reconstruit (nouvelle image, nouveau sticker…) reste ouvert s'il l'était, disque compris.
    private func keepOpen(_ fresh: AlbumNode) {
        ensureDisc()
        fresh.setDiscOut(true, animated: false)
    }

    /// Demi-tour vers l'autre face.
    func flip() {
        let face = ((ty - restY) / .pi).rounded()
        ty = restY + (face + 1) * .pi
        tx = restX
    }

    func reset() {
        let face = ((ty - restY) / (2 * .pi)).rounded()
        ty = restY + face * 2 * .pi
        tx = restX
        zoomTarget = 1
    }

    @objc private func tick(_ link: CADisplayLink) {
        // Ressorts calés sur le temps réel (comme les animations d'iOS) : identiques à 60 ou 120 images/s.
        let now = link.targetTimestamp
        let dt = lastTime == 0 ? 1.0 / 120 : min(max(now - lastTime, 1.0 / 240), 1.0 / 30)
        lastTime = now
        if !dragging {
            let k = 150.0
            let c = 2 * k.squareRoot() * 0.86
            vx += (k * (tx - rx) - c * vx) * dt
            vy += (k * (ty - ry) - c * vy) * dt
            rx += vx * dt
            ry += vy * dt
        }
        let kz = 230.0
        zoomV += (kz * (zoomTarget - zoom) - 2 * kz.squareRoot() * 0.8 * zoomV) * dt
        zoom += zoomV * dt
        let mx = motion?.x ?? 0
        let my = motion?.y ?? 0
        holder.eulerAngles = SCNVector3(Float(rx - my * 0.05), Float(ry + mx * 0.08), 0)
        cameraNode.position = SCNVector3(0, 0, Float(6.6 / zoom))
        let back = cos(ry) < 0
        if back != lastBack {
            lastBack = back
            onBackChange(back)
        }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view)
        switch g.state {
        case .began:
            dragging = true
            startX = rx
            startY = ry
        case .changed:
            // Horizontal : tourne librement. Vertical : simple inclinaison limitée, l'objet ne se couche jamais.
            ry = startY + Double(t.x) * 0.0095
            let tilt = Double(t.y) * 0.004
            rx = startX + tilt / (1 + abs(tilt) * 2.2)
            tx = rx
            ty = ry
        default:
            dragging = false
            // L'élan du geste choisit la face sur laquelle l'objet se pose (avant ou arrière).
            // L'élan du doigt est gardé : l'objet continue de tourner puis se pose.
            let spin = (Double(g.velocity(in: view).x) * 0.0095).clamped(-22, 22)
            let projected = ry + spin * 0.22
            let face = ((projected - restY) / .pi).rounded()
            ty = restY + face * .pi
            tx = restX
            vx = 0
            vy = spin
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        // Toucher l'objet le retourne.
        if !view.hitTest(g.location(in: view), options: nil).isEmpty { flip() }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began: pinchStart = zoomTarget
        case .changed: zoomTarget = (pinchStart * Double(g.scale)).clamped(0.75, 1.7)
        default: zoomTarget = zoomTarget.clamped(0.85, 1.5)
        }
    }

    @objc private func handleDoubleTap() { reset() }
}


// MARK: - Stickers holographiques

/// Choix des stickers posés sur un album (6 au maximum).
struct StickerPicker: View {
    let album: AlbumInfo
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var placing = false

    /// Les stickers se placent sur la pochette d'un CD ou la jaquette d'un jeu (pas sur les cassettes).
    private var canPlace: Bool {
        library.format(of: album.id, default: settings.shelfFormat) != .cassette
    }

    private var placerBackground: UIImage? {
        if let game = library.gameName(album.id) {
            return library.gameCoverImage(game)
                ?? AlbumNodeBuilder.generatedGameCover(title: game, season: GameCatalog.season(game),
                                                       count: album.tracks.count, platform: library.platform(of: game))
        }
        return library.extraImage("front", album.id) ?? library.image(for: album.cover)
    }

    private var placerAspect: CGFloat {
        guard library.gameName(album.id) != nil else { return 1 }
        return Physical.insert.width / Physical.insert.height
    }

    var body: some View {
        let chosen = library.stickers(for: album.id)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Touche un sticker pour le coller sur « \(album.title) » ou le retirer. Six au maximum.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        // Le reflet holographique ondule doucement.
                        let light = sin(context.date.timeIntervalSinceReferenceDate * 0.9)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 12) {
                            ForEach(AlbumBadge.stickers) { badge in
                                let on = chosen.contains(badge)
                                Button {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                        library.toggleSticker(badge, for: album.id)
                                    }
                                } label: {
                                    StickerTile(badge: badge, on: on, light: light)
                                }
                                .buttonStyle(PressStyle(circle: false))
                                .sensoryFeedback(.selection, trigger: on)
                            }
                        }
                    }
                    if canPlace {
                        Button {
                            placing = true
                        } label: {
                            Label("Placer les stickers sur la jaquette", systemImage: "hand.draw")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                    }
                    MyStickersSection(album: album, light: -0.3)
                        .padding(.top, 6)
                    if !library.stickerKeys(for: album.id).isEmpty {
                        Button(role: .destructive) {
                            withAnimation { library.clearStickers(for: album.id) }
                        } label: {
                            Label("Retirer tous les stickers", systemImage: "xmark.seal")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 4)
                    }
                }
                .padding(20)
            }
            .sheet(isPresented: $placing) {
                StickerPlacer(album: album, badges: library.badges(for: album),
                              background: placerBackground, aspect: placerAspect)
            }
            .navigationTitle("Stickers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

private struct StickerTile: View {
    let badge: AlbumBadge
    let on: Bool
    let light: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let border: Color = on ? .white.opacity(0.8) : .white.opacity(0.08)
        VStack(spacing: 10) {
            HoloBadge(badge: badge, light: light, scale: 1.6)
                .frame(height: 46)
            Text(badge.short)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(shape.fill(Color.white.opacity(on ? 0.16 : 0.05)))
        .overlay(shape.strokeBorder(border, lineWidth: on ? 1.5 : 1))
        .overlay(alignment: .topTrailing) {
            if on {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body)
                    .padding(6)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }
}


/// Onglets de la Collection : Albums (CD et cassettes) ou Jeux (bandes-son en boîtiers PS5).
private struct SectionSwitch: View {
    @Binding var section: Int
    let albums: Int
    let games: Int
    let vinyls: Int
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            tab(0, "Albums", "\(albums)", "opticaldisc")
            tab(1, "Jeux", "\(games)", "gamecontroller.fill")
            tab(2, "Vinyles", "\(vinyls)", "record.circle")
        }
        .padding(4)
        .glassCapsule()
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: section)
        .sensoryFeedback(.selection, trigger: section)
    }

    private func tab(_ index: Int, _ title: String, _ count: String, _ symbol: String) -> some View {
        let on = section == index
        return Button {
            section = index
        } label: {
            HStack(spacing: 5) {
                Text(title)
                Text(count).opacity(0.55)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(on ? Color.black : Color.white.opacity(0.85))
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background {
                if on { Capsule().fill(.white).matchedGeometryEffect(id: "pill", in: pill) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }
}


// MARK: - Recadrer une image au format de la jaquette

struct CropSource: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Place ta photo dans le cadre de la jaquette : glisse pour la déplacer, pince pour zoomer.
struct CoverCropper: View {
    /// Toute l'image posée dans un carré transparent (rien n'est coupé).
    static func fitted(_ image: UIImage) -> UIImage {
        let side = max(image.size.width, image.size.height, 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: (side - image.size.width) / 2, y: (side - image.size.height) / 2,
                                  width: image.size.width, height: image.size.height))
        }
    }

    let image: UIImage
    /// Largeur ÷ hauteur du cadre (jaquette PS5 : 135 ÷ 170).
    let aspect: CGFloat
    var title = "Jaquette"
    /// Cadre rond (pour un sticker rond).
    var round = false
    /// Bouton « Image entière » : garde toute l'image, sans rien couper (stickers).
    var fullImageOption = false
    var onDone: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var lastFrame: CGSize = CGSize(width: 300, height: 300)
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            // Barre du haut bien en dessous de l'heure et de la Dynamic Island, gros boutons faciles à toucher.
            HStack {
                Button { dismiss() } label: {
                    Text("Annuler")
                        .font(.body.weight(.medium))
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                Spacer()
                Text(title).font(.headline)
                Spacer()
                Button {
                    onDone(crop(frame: lastFrame))
                    dismiss()
                } label: {
                    Text("Utiliser")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background(Capsule().fill(Color.white))
                }
            }
            .buttonStyle(PressStyle(circle: false))
            .padding(.horizontal, 16)
            .padding(.top, topInset + 8)
            .padding(.bottom, 8)

            if fullImageOption {
                Button {
                    onDone(Self.fitted(image))
                    dismiss()
                } label: {
                    Label("Image entière, sans recadrer", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(PressStyle(circle: false))
                .padding(.bottom, 6)
            }

            // Zone de recadrage : sa taille ne dépend jamais de l'image (rien ne saute quand on zoome).
            GeometryReader { geo in
                let frame = frameSize(in: geo.size)
                let shown = shownSize(frame)
                ZStack {
                    Color.clear
                        .overlay {
                            Image(uiImage: image)
                                .resizable()
                                .frame(width: shown.width, height: shown.height)
                                .offset(offset)
                        }
                        .clipped()
                    // Tout ce qui dépasse du cadre est assombri.
                    Rectangle()
                        .fill(Color.black.opacity(0.65))
                        .reverseMask {
                            RoundedRectangle(cornerRadius: round ? frame.width / 2 : 8)
                                .frame(width: frame.width, height: frame.height)
                        }
                        .allowsHitTesting(false)
                    RoundedRectangle(cornerRadius: round ? frame.width / 2 : 8)
                        .strokeBorder(Color.white, lineWidth: 2)
                        .frame(width: frame.width, height: frame.height)
                        .allowsHitTesting(false)
                    if round {
                        // Le trou du disque, pour voir ce qui sera caché au centre.
                        Circle()
                            .fill(Color.black.opacity(0.75))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5))
                            .frame(width: frame.width * 0.27, height: frame.width * 0.27)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { g in
                            offset = clamp(CGSize(width: lastOffset.width + g.translation.width,
                                                  height: lastOffset.height + g.translation.height), frame: frame, scale: scale)
                        }
                        .onEnded { _ in lastOffset = offset }
                        .simultaneously(with:
                            MagnifyGesture()
                                .onChanged { g in
                                    scale = min(6, max(1, lastScale * g.magnification))
                                    offset = clamp(lastOffset, frame: frame, scale: scale)
                                }
                                .onEnded { _ in
                                    lastScale = scale
                                    lastOffset = offset
                                }
                        )
                )
                .onAppear { lastFrame = frame }
                .onChange(of: geo.size) { _, newSize in lastFrame = frameSize(in: newSize) }
            }

            Text("Glisse pour placer l’image · pince pour zoomer")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .frame(height: 50)
        }
        .padding(.bottom, bottomInset)
        .foregroundStyle(.white)
        .background(Color.black)
        .ignoresSafeArea()
    }

    /// Marges de l'écran (heure, Dynamic Island, barre du bas), lues sur la fenêtre elle-même.
    private var windowInsets: UIEdgeInsets {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        return window?.safeAreaInsets ?? UIEdgeInsets(top: 54, left: 0, bottom: 34, right: 0)
    }
    private var topInset: CGFloat { max(windowInsets.top, 47) }
    private var bottomInset: CGFloat { max(windowInsets.bottom, 20) }

    private func frameSize(in size: CGSize) -> CGSize {
        // Même un cadre très fin (la tranche) tient en entier à l'écran.
        let w = max(12, min(size.width - 48, (size.height - 40) * aspect))
        return CGSize(width: w, height: w / aspect)
    }

    /// L'image remplit toujours le cadre (échelle 1), puis on peut zoomer.
    private func baseScale(_ frame: CGSize) -> CGFloat {
        max(frame.width / max(image.size.width, 1), frame.height / max(image.size.height, 1))
    }

    private func shownSize(_ frame: CGSize, scale s: CGFloat? = nil) -> CGSize {
        let k = baseScale(frame) * (s ?? scale)
        return CGSize(width: image.size.width * k, height: image.size.height * k)
    }

    /// Empêche de faire sortir l'image du cadre (pas de bord vide).
    private func clamp(_ o: CGSize, frame: CGSize, scale s: CGFloat) -> CGSize {
        let shown = shownSize(frame, scale: s)
        let mx = max(0, (shown.width - frame.width) / 2)
        let my = max(0, (shown.height - frame.height) / 2)
        return CGSize(width: min(mx, max(-mx, o.width)), height: min(my, max(-my, o.height)))
    }

    /// Découpe la partie visible dans le cadre, en bonne définition.
    private func crop(frame: CGSize) -> UIImage {
        let k = baseScale(frame) * scale
        let shown = shownSize(frame)
        let x = ((shown.width - frame.width) / 2 - offset.width) / k
        let y = ((shown.height - frame.height) / 2 - offset.height) / k
        let rect = CGRect(x: x, y: y, width: frame.width / k, height: frame.height / k)
        let outW: CGFloat = min(1350, max(600, rect.width * image.scale))
        let out = CGSize(width: outW, height: outW / aspect)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: out, format: format).image { _ in
            let f = out.width / rect.width
            image.draw(in: CGRect(x: -rect.minX * f, y: -rect.minY * f,
                                  width: image.size.width * f, height: image.size.height * f))
        }
    }
}

extension View {
    /// Masque inversé : garde tout sauf la forme donnée.
    func reverseMask<M: View>(@ViewBuilder _ mask: () -> M) -> some View {
        self.mask {
            Rectangle()
                .overlay { mask().blendMode(.destinationOut) }
                .compositingGroup()
        }
    }
}


/// Console du boîtier de jeu : PS3, PS4 ou PS5.
private struct PlatformSwitch: View {
    let platform: GamePlatform
    var onChange: (GamePlatform) -> Void
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(GamePlatform.allCases) { p in
                let on = p == platform
                Button {
                    if !on { onChange(p) }
                } label: {
                    Text(p.label)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(on ? Color.black : Color.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background {
                            if on { Capsule().fill(.white).matchedGeometryEffect(id: "pill", in: pill) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? AccessibilityTraits.isSelected : AccessibilityTraits())
            }
        }
        .padding(4)
        .glassCapsule()
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: platform)
        .sensoryFeedback(.selection, trigger: platform)
    }
}

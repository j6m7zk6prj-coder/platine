import SwiftUI
import SceneKit
import UIKit

// MARK: - La collection en 3D

/// Tous tes albums en CD ou en cassette, en vrai volume : fais-les défiler, touche-les, fais-les tourner.
struct ShelfView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var motion = MotionTilt()
    @State private var focusedIndex = 0
    @State private var inspected: AlbumInfo?
    @State private var startIndex: Int?
    // État de l'album en main (gardé ici pour que la vue 3D reste chargée en permanence).
    @State private var discOut = false
    @State private var isBack = false
    @State private var flipToken = 0
    @State private var resetToken = 0

    private static let quick = Animation.smooth(duration: 0.22)

    var body: some View {
        let albums = library.albums
        let focused = albums.indices.contains(focusedIndex) ? albums[focusedIndex] : albums.first
        // La vue « en main » est déjà prête avec l'album au centre : l'ouverture est instantanée.
        let handAlbum = inspected ?? focused
        let isOpen = inspected != nil
        ZStack {
            Color(red: 0.03, green: 0.03, blue: 0.04).ignoresSafeArea()

            if albums.isEmpty {
                ContentUnavailableView("Aucun album", systemImage: "opticaldisc",
                                       description: Text("Importe de la musique pour remplir ta collection."))
            } else if let startIndex {
                ShelfSceneView(albums: albums, startIndex: startIndex, motion: motion, paused: isOpen,
                               onFocus: { focusedIndex = $0 },
                               onOpen: { i in open(albums[i]) })
                    .ignoresSafeArea()
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
                RadialGradient(colors: [library.palette(for: handAlbum.first)[1].opacity(0.35), .clear],
                               center: UnitPoint(x: 0.5, y: 0.42), startRadius: 10, endRadius: 380)
                    .ignoresSafeArea()
                    .opacity(isOpen ? 1 : 0)
                    .allowsHitTesting(false)

                InspectorSceneView(album: handAlbum, format: format, badges: library.badges(for: handAlbum),
                                   motion: motion, active: isOpen, discOut: discOut,
                                   spinning: playing && player.isPlaying,
                                   flipToken: flipToken, resetToken: resetToken,
                                   onBackChange: { isBack = $0 })
                    .ignoresSafeArea()
                    .opacity(isOpen ? 1 : 0)
                    .allowsHitTesting(isOpen)

                if let inspected {
                    ShelfInspector(album: inspected, format: format, isBack: isBack, discOut: $discOut,
                                   playingThisAlbum: playing,
                                   onFlip: { flipToken += 1 },
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
        .animation(Self.quick, value: isOpen)
        .sensoryFeedback(trigger: discOut) { _, _ in settings.haptics ? .impact(weight: .medium) : nil }
        .sensoryFeedback(trigger: isBack) { _, _ in settings.haptics && isOpen ? .impact(weight: .light) : nil }
        .onAppear {
            motion.start()
            if startIndex == nil {
                let playingAlbum = player.currentID.flatMap { library.track($0) }?.albumKey
                let i = albums.firstIndex { $0.id == playingAlbum } ?? 0
                focusedIndex = i
                startIndex = i
            }
        }
        .onDisappear { motion.stop() }
        .statusBarHidden()
    }

    private func isPlaying(_ album: AlbumInfo) -> Bool {
        guard let id = player.currentID else { return false }
        return album.tracks.contains { $0.id == id }
    }

    private func open(_ album: AlbumInfo) {
        discOut = false
        isBack = false
        inspected = album
    }

    private func close() {
        discOut = false
        inspected = nil
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Collection").font(.largeTitle.bold())
                Text("\(library.albums.count) album\(library.albums.count > 1 ? "s" : "")")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button { dismiss() } label: {
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
            VStack(spacing: 4) {
                Text(album.title)
                    .font(.title2.bold())
                    .lineLimit(1)
                Text([album.artist, album.year > 0 ? "\(album.year)" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                if !badges.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(badges) { HoloBadge(badge: $0, light: -0.3, scale: 1.25, showsText: true) }
                    }
                    .padding(.top, 6)
                }
            }
            .id(album.id)
            .transition(.opacity)

            HStack(spacing: 12) {
                Button { player.play(ids: album.tracks.map(\.id), shuffled: false) } label: {
                    Label("Lire", systemImage: "play.fill")
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .glassCapsule(interactive: true)
                }
                Button { open(album) } label: {
                    Label("Prendre en main", systemImage: "hand.point.up.left.fill")
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .glassCapsule(interactive: true)
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(PressStyle(circle: false))
        }
        .padding(.horizontal, 20)
        .animation(.smooth(duration: 0.3), value: album.id)
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
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings

    func makeCoordinator() -> ShelfSceneController {
        ShelfSceneController(builder: AlbumNodeBuilder(library: library, settings: settings), start: startIndex)
    }

    func makeUIView(context: Context) -> SCNView {
        let c = context.coordinator
        c.motion = motion
        c.onFocus = onFocus
        c.onOpen = onOpen
        c.update(albums: albums, library: library, settings: settings)
        c.start()
        c.setPaused(paused)
        return c.view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let c = context.coordinator
        c.onFocus = onFocus
        c.onOpen = onOpen
        c.update(albums: albums, library: library, settings: settings)
        c.setPaused(paused)
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: ShelfSceneController) {
        coordinator.stop()
    }
}

@MainActor
final class ShelfSceneController: NSObject {
    let view = SCNView()
    let scene = SCNScene()
    var builder: AlbumNodeBuilder
    var motion: MotionTilt?
    var onFocus: (Int) -> Void = { _ in }
    var onOpen: (Int) -> Void = { _ in }

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
        cameraNode.position = SCNVector3(0, 1.45, 9.4)
        cameraNode.look(at: SCNVector3(0, -0.05, 0))
        scene.rootNode.addChildNode(cameraNode)

        view.scene = scene
        view.pointOfView = cameraNode
        view.configureForShelf()

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(tap)
    }

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// Caché derrière l'album en main : le carrousel arrête de se redessiner.
    func setPaused(_ paused: Bool) {
        guard paused != (link?.isPaused ?? false) else { return }
        link?.isPaused = paused
        view.rendersContinuously = !paused
        view.isPlaying = !paused
    }

    func update(albums newAlbums: [AlbumInfo], library: Library, settings: AppSettings) {
        builder = AlbumNodeBuilder(library: library, settings: settings)
        albums = newAlbums
        formats = newAlbums.map { library.format(of: $0.id, default: settings.shelfFormat) }
        badges = newAlbums.map { library.badges(for: $0) }
        let ids = Set(newAlbums.map(\.id))
        for (id, node) in nodes where !ids.contains(id) {
            node.root.removeFromParentNode()
            nodes[id] = nil
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
    private func node(at i: Int, force: Bool = false) -> AlbumNode? {
        let album = albums[i]
        if let n = nodes[album.id] { return n }
        guard force || !builtThisFrame else { return nil }
        builtThisFrame = true
        let n = builder.make(album, format: formats[i], badges: badges[i], extras: false)
        // Ombre douce posée au sol.
        let w = CGFloat(n.size.x)
        let shadow = SCNPlane(width: w * 1.25, height: w * 0.45)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = AlbumNodeBuilder.contactShadow
        m.writesToDepthBuffer = false
        shadow.materials = [m]
        let shadowNode = SCNNode(geometry: shadow)
        shadowNode.eulerAngles.x = -.pi / 2
        shadowNode.position = SCNVector3(0, -n.size.y / 2 + 0.004, 0.05)
        n.root.addChildNode(shadowNode)
        n.root.opacity = 0
        scene.rootNode.addChildNode(n.root)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.35
        n.root.opacity = 1
        SCNTransaction.commit()
        nodes[album.id] = n
        return n
    }

    @objc private func tick() {
        builtThisFrame = false
        if !dragging {
            // Ressort façon iOS : rapide, sans rebond exagéré.
            vel = (vel + (target - pos) * 0.11) * 0.74
            pos += vel
            if abs(vel) < 0.0002 && abs(target - pos) < 0.0002 { pos = target; vel = 0 }
        }
        layout()
    }

    private func layout() {
        guard !albums.isEmpty else { return }
        let tiltX = motion?.x ?? 0
        let tiltY = motion?.y ?? 0
        let focus = Int((pos).rounded()).clamped(0, albums.count - 1)
        for i in albums.indices {
            let d = Double(i) - pos
            let ad = abs(d)
            let album = albums[i]
            if ad > 4.5 {
                nodes[album.id]?.root.isHidden = true
                continue
            }
            guard let n = node(at: i, force: ad < 0.6) else { continue }
            n.root.isHidden = false
            let s = d < 0 ? -1.0 : 1.0
            let e = min(ad, 1)
            let ease = e * e * (3 - 2 * e)
            let x = d * 0.55 + s * ease * 1.0
            let z = -ease * 1.1 - max(0, ad - 1) * 0.25
            let rotY = -s * ease * 1.0
            let scale = 1 - ease * 0.05
            let h = Double(n.size.y)
            n.root.position = SCNVector3(Float(x), Float(h / 2 + 0.001), Float(z))
            n.root.scale = SCNVector3(Float(scale), Float(scale), Float(scale))
            let isFocus = i == focus && ad < 0.5
            n.root.eulerAngles = SCNVector3(Float(isFocus ? -tiltY * 0.05 : 0), Float(rotY + (isFocus ? tiltX * 0.1 : 0)), 0)
        }
        if focus != lastFocus {
            lastFocus = focus
            haptic.selectionChanged()
            onFocus(focus)
            updateSpot(for: albums[focus])
        }
    }

    private func updateSpot(for album: AlbumInfo) {
        guard album.id != lastSpotAlbum, let spot = scene.rootNode.childNode(withName: "spot", recursively: false)?.light else { return }
        lastSpotAlbum = album.id
        let color = UIColor(builder.library.palette(for: album.first)[1])
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.8
        spot.color = color
        SCNTransaction.commit()
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let width = max(view.bounds.width, 1)
        let unit = Double(width) * 0.5
        switch g.state {
        case .began:
            dragging = true
            dragStart = pos
            vel = 0
        case .changed:
            let raw = dragStart - Double(g.translation(in: view).x) / unit
            let maxIndex = Double(albums.count - 1)
            // Résistance élastique aux extrémités.
            if raw < 0 { pos = -(1 - 1 / (1 + -raw * 0.55)) * 1.1 }
            else if raw > maxIndex { pos = maxIndex + (1 - 1 / (1 + (raw - maxIndex) * 0.55)) * 1.1 }
            else { pos = raw }
        default:
            dragging = false
            let v = -Double(g.velocity(in: view).x) / unit
            let projected = pos + v * 0.25
            target = projected.rounded().clamped(0, Double(albums.count - 1))
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let hits = view.hitTest(g.location(in: view), options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
        guard let hit = hits.first?.node else { return }
        for (i, album) in albums.enumerated() {
            guard let n = nodes[album.id] else { continue }
            var cur: SCNNode? = hit
            while let c = cur, c !== n.root { cur = c.parent }
            if cur != nil {
                if i == Int(target.rounded()) { onOpen(i) } else { target = Double(i) }
                return
            }
        }
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}

// MARK: - Prendre un album en main

struct ShelfInspector: View {
    let album: AlbumInfo
    let format: AlbumFormat
    let isBack: Bool
    @Binding var discOut: Bool
    let playingThisAlbum: Bool
    var onFlip: () -> Void
    var onFormat: (AlbumFormat) -> Void
    var onClose: () -> Void
    @Environment(Player.self) private var player

    var body: some View {
        let spinning = playingThisAlbum && player.isPlaying
        VStack(spacing: 16) {
            HStack {
                FormatSwitch(format: format, onChange: onFormat)
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

            Text("Glisse pour tourner · touche pour retourner · pince pour zoomer · touche deux fois pour remettre droit")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .allowsHitTesting(false)

            HStack(spacing: 10) {
                inspectorButton(format == .cassette ? (isBack ? "Face A" : "Face B") : (isBack ? "Face" : "Dos"),
                                symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", action: onFlip)
                if format == .cd {
                    inspectorButton(discOut ? "Ranger le CD" : "Sortir le CD", symbol: "opticaldisc") {
                        if !discOut && !playingThisAlbum { playAlbum() }
                        discOut.toggle()
                    }
                }
                inspectorButton(spinning ? "Pause" : "Lire", symbol: spinning ? "pause.fill" : "play.fill") {
                    if playingThisAlbum { player.togglePlay() } else { playAlbum() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 26)
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
            .glass(18, interactive: true)
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
    let flipToken: Int
    let resetToken: Int
    var onBackChange: (Bool) -> Void
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings

    func makeCoordinator() -> InspectorSceneController { InspectorSceneController() }

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
        let builder = AlbumNodeBuilder(library: library, settings: settings)
        c.show(album: album, format: format, badges: badges, builder: builder, animated: active)
        c.setActive(active)
        if discOut { c.ensureDisc() }
        c.node?.setDiscOut(discOut && active)
        c.node?.setSpinning(active && spinning && (format == .cassette || discOut))
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: InspectorSceneController) {
        coordinator.stop()
    }
}

@MainActor
final class InspectorSceneController: NSObject {
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

        view.scene = scene
        view.pointOfView = cameraNode
        view.configureForShelf()
        // En veille au départ : la vue se dessine une fois (shaders prêts) puis attend.
        view.rendersContinuously = false
        view.isPlaying = false

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        single.require(toFail: double)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(double)
        view.addGestureRecognizer(single)
    }

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// Allume ou met en veille la vue « en main ». En veille elle ne consomme rien,
    /// mais reste prête : l'ouvrir est instantané.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            // L'objet arrive en pivotant légèrement, comme quand on le prend en main.
            rx = restX; tx = restX
            ry = restY + 0.55; ty = restY
            vx = 0; vy = 0
            zoom = 0.9; zoomTarget = 1
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
        guard let node, node.format == .cd, !node.hasDisc, let builder, let album else { return }
        node.attachDisc(builder.makeDisc(album))
    }

    func show(album: AlbumInfo, format: AlbumFormat, badges: [AlbumBadge], builder: AlbumNodeBuilder, animated: Bool) {
        self.builder = builder
        self.album = album
        let sig = builder.signature(album, format, badges)
        guard node?.signature != sig else { return }
        let old = node
        let fresh = builder.make(album, format: format, badges: badges, extras: false)
        guard animated else {
            old?.root.removeFromParentNode()
            holder.addChildNode(fresh.root)
            node = fresh
            return
        }
        fresh.root.opacity = 0
        fresh.root.scale = SCNVector3(0.92, 0.92, 0.92)
        holder.addChildNode(fresh.root)
        node = fresh
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

    @objc private func tick() {
        if !dragging {
            // Ressort doux et amorti : l'objet se pose sans à-coup.
            vx = (vx + (tx - rx) * 0.07) * 0.78
            vy = (vy + (ty - ry) * 0.07) * 0.78
            rx += vx
            ry += vy
        }
        zoom += (zoomTarget - zoom) * 0.18
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
            let projected = ry + Double(g.velocity(in: view).x) * 0.0095 * 0.22
            let face = ((projected - restY) / .pi).rounded()
            ty = restY + face * .pi
            tx = restX
            vx = 0
            vy = 0
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

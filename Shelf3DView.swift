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

    var body: some View {
        let albums = library.albums
        let focused = albums.indices.contains(focusedIndex) ? albums[focusedIndex] : albums.first
        ZStack {
            Color(red: 0.03, green: 0.03, blue: 0.04).ignoresSafeArea()

            if albums.isEmpty {
                ContentUnavailableView("Aucun album", systemImage: "opticaldisc",
                                       description: Text("Importe de la musique pour remplir ta collection."))
            } else if let startIndex {
                ShelfSceneView(albums: albums, startIndex: startIndex, motion: motion,
                               onFocus: { focusedIndex = $0 },
                               onOpen: { i in withAnimation(.smooth(duration: 0.45)) { inspected = albums[i] } })
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if let focused { caption(focused) }
            }
            .padding(.bottom, 30)

            if let inspected {
                ShelfInspector(album: inspected, motion: motion) {
                    withAnimation(.smooth(duration: 0.45)) { self.inspected = nil }
                }
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .foregroundStyle(.white)
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
                        ForEach(badges) { HoloBadge(badge: $0, light: motion.x, scale: 1.25, showsText: true) }
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
                Button { withAnimation(.smooth(duration: 0.45)) { inspected = album } } label: {
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
        return c.view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let c = context.coordinator
        c.onFocus = onFocus
        c.onOpen = onOpen
        c.update(albums: albums, library: library, settings: settings)
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
        camera.fieldOfView = 38
        camera.wantsHDR = true
        camera.bloomIntensity = 0.25
        camera.bloomThreshold = 0.9
        camera.zNear = 0.1
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 1.05, 5.6)
        cameraNode.look(at: SCNVector3(0, -0.15, 0))
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

    private func node(at i: Int) -> AlbumNode {
        let album = albums[i]
        if let n = nodes[album.id] { return n }
        let n = builder.make(album, format: formats[i], badges: badges[i], extras: false)
        scene.rootNode.addChildNode(n.root)
        nodes[album.id] = n
        return n
    }

    @objc private func tick() {
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
            let n = node(at: i)
            n.root.isHidden = false
            let s = d < 0 ? -1.0 : 1.0
            let e = min(ad, 1)
            let x = d * 0.6 + s * e * 0.95
            let z = -e * 1.2 - max(0, ad - 1) * 0.3
            let rotY = -s * e * 1.12
            let scale = 1 - e * 0.06
            let h = Double(n.size.y)
            n.root.position = SCNVector3(Float(x), Float(h / 2 + 0.001), Float(z))
            n.root.scale = SCNVector3(Float(scale), Float(scale), Float(scale))
            let isFocus = i == focus && ad < 0.5
            n.root.eulerAngles = SCNVector3(Float(isFocus ? -tiltY * 0.08 : 0), Float(rotY + (isFocus ? tiltX * 0.14 : 0)), 0)
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
        let unit = Double(width) * 0.42
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
            let projected = pos + v * 0.32
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
    let motion: MotionTilt
    var onClose: () -> Void
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var discOut = false
    @State private var isBack = false
    @State private var flipToken = 0
    @State private var resetToken = 0

    private var format: AlbumFormat { library.format(of: album.id, default: settings.shelfFormat) }

    private var playingThisAlbum: Bool {
        guard let id = player.currentID else { return false }
        return album.tracks.contains { $0.id == id }
    }

    var body: some View {
        let format = self.format
        let badges = library.badges(for: album)
        let spinning = playingThisAlbum && player.isPlaying
        ZStack {
            ZStack {
                Color(red: 0.03, green: 0.03, blue: 0.04)
                RadialGradient(colors: [library.palette(for: album.first)[1].opacity(0.35), .clear],
                               center: UnitPoint(x: 0.5, y: 0.42), startRadius: 10, endRadius: 380)
            }
            .ignoresSafeArea()

            InspectorSceneView(album: album, format: format, badges: badges, motion: motion,
                               discOut: discOut, spinning: spinning, flipToken: flipToken, resetToken: resetToken,
                               onBackChange: { isBack = $0 })
                .ignoresSafeArea()

            VStack(spacing: 16) {
                HStack {
                    FormatSwitch(format: format) { newValue in
                        discOut = false
                        resetToken += 1
                        library.setFormat(newValue, for: album.id)
                    }
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

                VStack(spacing: 4) {
                    Text(album.title).font(.title2.bold()).lineLimit(1)
                    Text(album.artist).font(.headline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }

                Text("Fais glisser pour tourner · pince pour zoomer · touche deux fois pour remettre droit")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)

                HStack(spacing: 10) {
                    inspectorButton(format == .cassette ? (isBack ? "Face A" : "Face B") : (isBack ? "Face" : "Dos"),
                                    symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                        flipToken += 1
                    }
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
        .sensoryFeedback(trigger: discOut) { _, _ in settings.haptics ? .impact(weight: .medium) : nil }
        .sensoryFeedback(trigger: isBack) { _, _ in settings.haptics ? .impact(weight: .light) : nil }
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
        c.start()
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
        c.show(album: album, format: format, badges: badges, builder: builder)
        c.node?.setDiscOut(discOut)
        c.node?.setSpinning(spinning && (format == .cassette || discOut))
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

    // Rotation : position actuelle, cible et vitesse (ressort).
    private var rx: Double = -0.12, ry: Double = 0.35
    private var tx: Double = -0.12, ty: Double = 0.35
    private var vx: Double = 0, vy: Double = 0
    private var startX: Double = 0, startY: Double = 0
    private var dragging = false
    private var zoom: Double = 1, zoomTarget: Double = 1, pinchStart: Double = 1
    private var lastBack = false

    override init() {
        super.init()
        Studio.addLights(to: scene, withFloor: false)
        let camera = SCNCamera()
        camera.fieldOfView = 34
        camera.wantsHDR = true
        camera.bloomIntensity = 0.2
        camera.bloomThreshold = 0.9
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 5.0)
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(holder)
        holder.position = SCNVector3(0, 0.35, 0)

        view.scene = scene
        view.pointOfView = cameraNode
        view.configureForShelf()

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        double.numberOfTapsRequired = 2
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(double)
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

    func show(album: AlbumInfo, format: AlbumFormat, badges: [AlbumBadge], builder: AlbumNodeBuilder) {
        let sig = builder.signature(album, format, badges)
        guard node?.signature != sig else { return }
        let old = node
        let fresh = builder.make(album, format: format, badges: badges, extras: true)
        fresh.root.opacity = 0
        fresh.root.scale = SCNVector3(0.9, 0.9, 0.9)
        holder.addChildNode(fresh.root)
        node = fresh
        SCNTransaction.begin()
        SCNTransaction.animationDuration = old == nil ? 0.35 : 0.45
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
        fresh.root.opacity = 1
        fresh.root.scale = SCNVector3(1, 1, 1)
        old?.root.opacity = 0
        old?.root.scale = SCNVector3(1.06, 1.06, 1.06)
        SCNTransaction.completionBlock = { old?.root.removeFromParentNode() }
        SCNTransaction.commit()
    }

    func flip() {
        // Passe à l'autre face : demi-tour exact depuis la face la plus proche.
        ty = (ty / .pi).rounded() * .pi + .pi
        tx = 0
    }

    func reset() {
        tx = -0.12
        ty = (ty / (2 * .pi)).rounded() * 2 * .pi + 0.35
        zoomTarget = 1
    }

    @objc private func tick() {
        if !dragging {
            vx = (vx + (tx - rx) * 0.085) * 0.8
            vy = (vy + (ty - ry) * 0.085) * 0.8
            rx += vx
            ry += vy
        }
        zoom += (zoomTarget - zoom) * 0.2
        let mx = motion?.x ?? 0
        let my = motion?.y ?? 0
        holder.eulerAngles = SCNVector3(Float(rx - my * 0.08), Float(ry + mx * 0.12), 0)
        cameraNode.position = SCNVector3(0, 0, Float(5.0 / zoom))
        let back = cos(ry) * cos(rx) < 0
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
            // Suit le doigt sans aucun délai.
            ry = startY + Double(t.x) * 0.0105
            rx = (startX + Double(t.y) * 0.0085).clamped(-1.15, 1.15)
            tx = rx
            ty = ry
        default:
            dragging = false
            let v = g.velocity(in: view)
            // Élan : la cible est projetée selon la vitesse réelle du geste.
            ty = ry + Double(v.x) * 0.0105 * 0.28
            tx = (rx + Double(v.y) * 0.0085 * 0.2).clamped(-1.15, 1.15)
            vx = 0
            vy = 0
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began: pinchStart = zoomTarget
        case .changed: zoomTarget = (pinchStart * Double(g.scale)).clamped(0.7, 1.9)
        default: zoomTarget = zoomTarget.clamped(0.8, 1.6)
        }
    }

    @objc private func handleDoubleTap() { reset() }
}

import SwiftUI
import AVKit
import ImageIO
import MediaPlayer
import UIKit

// MARK: - Surfaces
// Style classique (comme l'iTunes Store et Musique d'avant iOS 26) : surfaces pleines, fin liseré, sans verre.
// Les noms .glass… sont gardés pour ne pas toucher au reste de l'app.

extension View {
    func glass(_ radius: CGFloat = 12, interactive: Bool = false) -> some View {
        modifier(ClassicSurface(shape: RoundedRectangle(cornerRadius: min(radius, 12), style: .continuous)))
    }

    func glassCapsule(interactive: Bool = false) -> some View {
        modifier(ClassicSurface(shape: Capsule()))
    }

    func glassCircle() -> some View {
        modifier(ClassicSurface(shape: Circle()))
    }

    func frostedGlass<S: InsettableShape>(_ shape: S) -> some View {
        modifier(ClassicSurface(shape: shape))
    }
}

/// Surface pleine grise (s'adapte au mode clair / sombre), bordée d'un trait fin comme les cellules iOS.
struct ClassicSurface<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content
            .background(shape.fill(Color(.secondarySystemBackground)))
            .overlay { shape.strokeBorder(Color(.separator), lineWidth: 0.5) }
    }
}

// MARK: - Bouton qui s'enfonce

struct PressStyle: ButtonStyle {
    /// Gardé pour compatibilité : plus aucun rond blanc derrière les boutons.
    var circle = true

    func makeBody(configuration: Configuration) -> some View {
        // Comme Apple : le bouton s'enfonce et s'assombrit légèrement, sans halo ni rond.
        configuration.label
            .scaleEffect(configuration.isPressed ? (circle ? 0.86 : 0.97) : 1)
            .opacity(configuration.isPressed ? 0.62 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.06) : .spring(response: 0.34, dampingFraction: 0.62),
                       value: configuration.isPressed)
    }
}

// MARK: - Boutons façon iTunes Store

/// Le bouton « prix » de l'iTunes Store : contour bleu en pilule ; enfoncé, il se remplit de bleu.
struct OutlineButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        OutlineLabel(configuration: configuration, compact: compact)
    }

    private struct OutlineLabel: View {
        let configuration: Configuration
        let compact: Bool
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font((compact ? Font.subheadline : .body).weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(configuration.isPressed ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(.tint))
                .padding(.horizontal, compact ? 12 : 18)
                .frame(minHeight: compact ? 28 : 36)
                .background { Capsule().fill(configuration.isPressed ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear)) }
                .overlay { Capsule().strokeBorder(.tint, lineWidth: 1.2) }
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.4)
        }
    }
}

/// Bouton plein (action principale) : fond bleu, texte blanc, coins légèrement arrondis.
struct FilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.tint))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Bouton de barre d'outils : icône bleue et petit texte dessous, comme les anciennes barres iOS.
struct ToolbarItemButton: View {
    let title: String
    let symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 21))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(height: 26)
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(.tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(circle: false))
    }
}

// MARK: - Pochette (image, GIF animé ou vidéo en boucle)

struct ArtworkView: View {
    let track: Track?
    var animated = true
    var small = false
    var cornerRadius: CGFloat = 12
    /// Fin liseré autour de la pochette (retiré quand elle prend tout l'écran).
    var bordered = true
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings

    var body: some View {
        // Réglage « Pochettes carrées » : coins presque droits.
        let radius = settings.artworkStyle == .square ? min(cornerRadius, cornerRadius >= 25 ? cornerRadius : 2) : cornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(Color(.tertiarySystemFill))
            // La note de musique n'apparaît que s'il n'y a vraiment aucune pochette
            // (jamais en transparence derrière une pochette animée).
            .overlay { if !hasArtwork { placeholder } }
            .overlay { content }
            .clipShape(shape)
            // Comme l'iTunes Store : un fin trait gris autour de chaque pochette.
            .overlay { if bordered { shape.strokeBorder(Color(.separator), lineWidth: 0.5) } }
    }

    private var hasArtwork: Bool {
        guard let t = track else { return false }
        return library.artworkURL(t) != nil
    }

    @ViewBuilder private var content: some View {
        if let t = track, let url = library.artworkURL(t) {
            // La pochette animée s'affiche là où l'animation est permise ; sinon la normale.
            let moving = animated && settings.animatedArtwork ? library.motion(t) : nil
            Group {
                if let moving, moving.kind == .video {
                    LoopingVideoView(url: moving.url)
                } else if let moving, moving.kind == .gif {
                    AnimatedImageView(url: moving.url)
                } else if let img = small ? library.thumbnail(for: t) : library.image(for: t) {
                    Image(uiImage: img).resizable().scaledToFill()
                }
            }
            .id(url)
            .transition(.opacity)
        }
    }

    private var placeholder: some View {
        GeometryReader { geo in
            Image(systemName: "music.note")
                .font(.system(size: max(10, geo.size.width * 0.3), weight: .medium))
                .foregroundStyle(Color(.tertiaryLabel))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// Vidéo muette en boucle.
final class LoopingVideoUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private let queuePlayer = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var url: URL?
    private var foregroundObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        queuePlayer.isMuted = true
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        playerLayer.player = queuePlayer
        playerLayer.videoGravity = .resizeAspectFill
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.queuePlayer.play() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(_ url: URL) {
        guard url != self.url else { return }
        self.url = url
        queuePlayer.removeAllItems()
        looper = AVPlayerLooper(player: queuePlayer, templateItem: AVPlayerItem(url: url))
        queuePlayer.play()
    }

    func stop() {
        queuePlayer.pause()
        looper = nil
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }
}

struct LoopingVideoView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> LoopingVideoUIView {
        let view = LoopingVideoUIView()
        view.load(url)
        return view
    }

    func updateUIView(_ uiView: LoopingVideoUIView, context: Context) { uiView.load(url) }

    static func dismantleUIView(_ uiView: LoopingVideoUIView, coordinator: ()) { uiView.stop() }
}

// GIF animé, décodé hors du fil principal.
let gifCache = NSCache<NSURL, UIImage>()

enum GIFDecoder {
    static func decode(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 900
        ] as CFDictionary
        var frames: [UIImage] = []
        var total = 0.0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, i, options) else { continue }
            var delay = 0.1
            if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
               let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                    ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            }
            if delay < 0.02 { delay = 0.1 }
            total += delay
            frames.append(UIImage(cgImage: cg))
        }
        if frames.count <= 1 { return frames.first }
        return UIImage.animatedImage(with: frames, duration: total)
    }
}

final class AnimatedImageContainer: UIView {
    private let imageView = UIImageView()
    private var url: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(_ url: URL) {
        guard url != self.url else { return }
        self.url = url
        if let cached = gifCache.object(forKey: url as NSURL) {
            imageView.image = cached
            return
        }
        imageView.image = nil
        Task { @MainActor [weak self] in
            let image = await Task.detached(priority: .userInitiated) { GIFDecoder.decode(url) }.value
            guard let self, self.url == url, let image else { return }
            gifCache.setObject(image, forKey: url as NSURL)
            UIView.transition(with: self.imageView, duration: 0.35, options: .transitionCrossDissolve) {
                self.imageView.image = image
            }
        }
    }
}

struct AnimatedImageView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> AnimatedImageContainer {
        let view = AnimatedImageContainer()
        view.load(url)
        return view
    }

    func updateUIView(_ uiView: AnimatedImageContainer, context: Context) { uiView.load(url) }
}

// MARK: - Fond liquide teinté par la pochette

struct AmbientBackground: View {
    let track: Track?
    var dim: Double = 0.3
    /// Écran « En lecture » : reste sombre même avec un thème clair.
    var forceDark = false
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var drift = false

    private var theme: AppTheme {
        let t = settings.activeTheme
        if forceDark && t.isLight { return .dynamic }
        return t
    }

    var body: some View {
        if forceDark {
            playerBackground
        } else {
            // Style classique : fond uni du système (noir en mode sombre, blanc en mode clair).
            Color(.systemBackground).ignoresSafeArea()
        }
    }

    private var playerBackground: some View {
        Group {
            switch theme {
            case .dynamic: dynamicBackground(light: false)
            case .light: dynamicBackground(light: true)
            case .black: Color.black
            case .white: Color.white
            case .graphite:
                LinearGradient(colors: [Color(white: 0.15), Color(white: 0.07)], startPoint: .top, endPoint: .bottom)
            case .midnight:
                ZStack {
                    LinearGradient(colors: [Color(red: 0.07, green: 0.1, blue: 0.24), Color(red: 0.02, green: 0.03, blue: 0.09)],
                                   startPoint: .top, endPoint: .bottom)
                    RadialGradient(colors: [Color(red: 0.25, green: 0.3, blue: 0.7).opacity(0.35), .clear],
                                   center: .topTrailing, startRadius: 0, endRadius: 500)
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: settings.activeTheme)
    }

    private func dynamicBackground(light: Bool) -> some View {
        let colors = settings.dynamicBackground ? (track.map { library.palette(for: $0) } ?? Palette.defaults) : Palette.defaults
        return GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height)
            ZStack {
                if light { Color(white: 0.97) } else { colors[0] }
                if settings.dynamicBackground, let t = track, let img = library.backdrop(for: t) {
                    Image(uiImage: img)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(1.4)
                        .opacity(light ? 0.22 : 0.55)
                        .id(library.artworkURL(t))
                        .transition(.opacity)
                }
                Circle()
                    .fill(RadialGradient(colors: [colors[1], .clear], center: .center, startRadius: 0, endRadius: side * 0.45))
                    .frame(width: side * 0.9, height: side * 0.9)
                    .offset(x: drift ? side * 0.18 : -side * 0.22, y: drift ? -side * 0.3 : -side * 0.12)
                    .opacity(light ? 0.25 : 0.75)
                Circle()
                    .fill(RadialGradient(colors: [colors[2], .clear], center: .center, startRadius: 0, endRadius: side * 0.42))
                    .frame(width: side * 0.85, height: side * 0.85)
                    .offset(x: drift ? -side * 0.2 : side * 0.2, y: drift ? side * 0.32 : side * 0.14)
                    .opacity(light ? 0.2 : 0.65)
                if light { Color.white.opacity(0.55) } else { Color.black.opacity(dim) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            // Tout le fond est dessiné d'un bloc par le processeur graphique : défilement plus fluide.
            .drawingGroup()
        }
        .animation(.easeInOut(duration: 1.3), value: colors)
        .animation(.easeInOut(duration: 1.0), value: track.flatMap { library.artworkURL($0) })
        .onAppear {
            guard settings.backgroundMotion else { return }
            withAnimation(.easeInOut(duration: 17).repeatForever(autoreverses: true)) { drift = true }
        }
        .onChange(of: settings.backgroundMotion) { _, on in
            withAnimation(on ? .easeInOut(duration: 17).repeatForever(autoreverses: true) : .easeInOut(duration: 1)) { drift = on }
        }
    }
}

// MARK: - Barre de progression façon Apple

struct Scrubber: View {
    @Environment(Player.self) private var player
    @State private var dragValue: Double?
    @State private var grabStart: Double?

    var body: some View {
        let total = max(player.duration, 0.01)
        let value = min(total, dragValue ?? player.currentTime)
        let active = dragValue != nil
        VStack(spacing: 4) {
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let x = width * value / total
                // Style classique : une fine barre avec son point, qui grossit quand on le tient.
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemFill)).frame(height: 3)
                    Capsule().fill(Color(.secondaryLabel)).frame(width: max(0, x), height: 3)
                    Circle()
                        .fill(Color(.secondaryLabel))
                        .frame(width: active ? 22 : 8, height: active ? 22 : 8)
                        .shadow(color: .black.opacity(active ? 0.2 : 0), radius: 3, y: 1)
                        .offset(x: max(0, min(width, x)) - (active ? 11 : 4))
                }
                .animation(active ? nil : .linear(duration: 0.25), value: value)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if grabStart == nil { grabStart = min(total, player.currentTime) }
                            guard let start = grabStart else { return }
                            player.isScrubbing = true
                            let moved = Double(g.location.x - g.startLocation.x) / Double(width) * total
                            dragValue = min(total, max(0, start + moved))
                        }
                        .onEnded { _ in
                            if let start = grabStart, let v = dragValue, abs(v - start) > 0.3 { player.seek(to: v) }
                            dragValue = nil
                            grabStart = nil
                            player.isScrubbing = false
                        }
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: active)
            }
            .frame(height: 26)
            .sensoryFeedback(.selection, trigger: active)

            HStack {
                Text(formatTime(value))
                Spacer()
                Text("-" + formatTime(total - value))
            }
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(formatTime(value)) sur \(formatTime(total))")
        .accessibilityAdjustableAction { direction in
            let step = 10.0
            switch direction {
            case .increment: player.seek(to: min(total, player.currentTime + step))
            case .decrement: player.seek(to: max(0, player.currentTime - step))
            @unknown default: break
            }
        }
    }
}

// MARK: - Volume système et AirPlay

struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.tintColor = .secondaryLabel
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 14, height: 14)).image { ctx in
            UIColor.secondaryLabel.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 1, y: 1, width: 12, height: 12))
        }
        view.setVolumeThumbImage(thumb, for: .normal)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .systemBlue
        view.activeTintColor = .systemBlue
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}


// MARK: - Badge « E » (contenu explicite)

/// Le petit carré « E » d'Apple Music, à côté du titre d'un morceau explicite.
struct ExplicitBadge: View {
    var size: CGFloat = 15

    var body: some View {
        Text("E")
            .font(.system(size: size * 0.68, weight: .heavy, design: .rounded))
            .foregroundStyle(.background)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).fill(.secondary))
            .accessibilityLabel("Explicite")
    }
}

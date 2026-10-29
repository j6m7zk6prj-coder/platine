import SwiftUI
import AVKit
import ImageIO
import MediaPlayer
import UIKit

// MARK: - Verre liquide
// iOS 26 : le vrai Liquid Glass d'Apple. Avant : un verre dépoli avec un liseré lumineux.

extension View {
    func glass(_ radius: CGFloat = 24, interactive: Bool = false) -> some View {
        modifier(GlassStyle(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), interactive: interactive))
    }

    func glassCapsule(interactive: Bool = false) -> some View {
        modifier(GlassStyle(shape: Capsule(), interactive: interactive))
    }

    func glassCircle() -> some View {
        modifier(GlassStyle(shape: Circle(), interactive: true))
    }

    func frostedGlass<S: InsettableShape>(_ shape: S) -> some View {
        self
            .background(.ultraThinMaterial, in: shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05), .white.opacity(0.18)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
    }
}

/// Le verre de l'app, réglable dans Réglages → Apparence :
/// Liquid Glass plus ou moins transparent, ou désactivé (surfaces pleines, plus sobres).
struct GlassStyle<S: InsettableShape>: ViewModifier {
    let shape: S
    var interactive = false
    @Environment(AppSettings.self) private var settings: AppSettings?

    func body(content: Content) -> some View {
        let enabled = settings?.liquidGlass ?? true
        // 0 = verre presque opaque et sombre, 1 = verre très transparent.
        let intensity = settings?.glassIntensity ?? 0.6
        if !enabled {
            content
                .background(shape.fill(Color(white: 0.13)))
                .overlay { shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.75) }
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
        } else {
            liquid(content, intensity: intensity)
        }
    }

    @ViewBuilder private func liquid(_ content: Content, intensity: Double) -> some View {
        let tint = Color.black.opacity((1 - intensity) * 0.55)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let base: Glass = intensity > 0.85 ? .clear : .regular
            let glass = base.tint(tint)
            if interactive {
                content.glassEffect(glass.interactive(), in: shape)
            } else {
                content.glassEffect(glass, in: shape)
            }
        } else {
            content
                .background(shape.fill(tint))
                .frostedGlass(shape)
        }
        #else
        content
            .background(shape.fill(tint))
            .frostedGlass(shape)
        #endif
    }
}

// MARK: - Bouton qui s'enfonce

struct PressStyle: ButtonStyle {
    var circle = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if circle {
                    Circle()
                        .fill(.white.opacity(configuration.isPressed ? 0.14 : 0))
                        .scaleEffect(configuration.isPressed ? 1 : 0.6)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            // Réaction immédiate au toucher (enfoncement très court), puis rebond doux au relâchement.
            .animation(configuration.isPressed ? .easeOut(duration: 0.08) : .spring(response: 0.32, dampingFraction: 0.58),
                       value: configuration.isPressed)
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
            .fill(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.05)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            // La note de musique n'apparaît que s'il n'y a vraiment aucune pochette
            // (jamais en transparence derrière une pochette animée).
            .overlay { if !hasArtwork { placeholder } }
            .overlay { content }
            .clipShape(shape)
            .overlay { if bordered { shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5) } }
    }

    private var hasArtwork: Bool {
        guard let t = track else { return false }
        return library.artworkURL(t) != nil
    }

    @ViewBuilder private var content: some View {
        if let t = track, let url = library.artworkURL(t) {
            let kind = library.artworkKind(t)
            Group {
                if animated && settings.animatedArtwork && kind == .video {
                    LoopingVideoView(url: url)
                } else if animated && settings.animatedArtwork && kind == .gif {
                    AnimatedImageView(url: url)
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
                .foregroundStyle(.white.opacity(0.35))
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
    /// Position du morceau au moment où on a attrapé le point.
    @State private var grabStart: Double?

    var body: some View {
        let total = max(player.duration, 0.01)
        let value = min(total, dragValue ?? player.currentTime)
        let active = dragValue != nil
        VStack(spacing: 6) {
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let x = width * value / total
                // Comme Musique : une barre épaisse, sans point, qui grossit quand on la tient.
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule()
                        .fill(.white.opacity(active ? 1 : 0.6))
                        .frame(width: max(0, x))
                }
                .frame(height: active ? 12 : 7)
                .animation(active ? nil : .linear(duration: 0.25), value: value)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if grabStart == nil {
                                // On glisse depuis n'importe où : la barre avance du même chemin que le doigt.
                                // Un simple toucher ne fait jamais sauter le morceau.
                                grabStart = min(total, player.currentTime)
                            }
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
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: active)
            }
            .frame(height: 28)
            .scaleEffect(x: active ? 1.03 : 1, y: 1)
            .sensoryFeedback(.selection, trigger: active)

            HStack {
                Text(formatTime(value))
                Spacer()
                Text("-" + formatTime(total - value))
            }
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(active ? 0.85 : 0.5))
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
        view.tintColor = .white
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 14, height: 14)).image { ctx in
            UIColor.white.setFill()
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
        view.tintColor = UIColor(white: 1, alpha: 0.75)
        view.activeTintColor = .white
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

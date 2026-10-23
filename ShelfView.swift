import SwiftUI
import CoreMotion

// MARK: - Inclinaison de l'iPhone (reflets et holographique qui bougent avec le téléphone)

@Observable
final class MotionTilt {
    var x: Double = 0
    var y: Double = 0
    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var base: CMAttitude?

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60
        manager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let attitude = data.attitude
            if self.base == nil { self.base = attitude.copy() as? CMAttitude }
            if let base = self.base { attitude.multiply(byInverseOf: base) }
            // Lissage léger pour un mouvement sans à-coups.
            let nx = max(-1, min(1, attitude.roll / 0.6))
            let ny = max(-1, min(1, attitude.pitch / 0.6))
            self.x += (nx - self.x) * 0.25
            self.y += (ny - self.y) * 0.25
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        base = nil
    }
}

// MARK: - La collection

/// Tous tes albums en CD ou en cassette : fais-les défiler, touche-les, fais-les tourner.
struct ShelfView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var motion = MotionTilt()
    @State private var focusedID: String?
    @State private var inspected: AlbumInfo?

    private let itemWidth: CGFloat = 250

    var body: some View {
        let albums = library.albums
        let focused = albums.first { $0.id == focusedID } ?? albums.first
        GeometryReader { geo in
            ZStack {
                ShelfBackground(album: focused)

                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 10)
                    if albums.isEmpty {
                        ContentUnavailableView("Aucun album", systemImage: "opticaldisc",
                                               description: Text("Importe de la musique pour remplir ta collection."))
                    } else {
                        carousel(albums, width: geo.size.width)
                        Spacer(minLength: 10)
                        if let focused { caption(focused) }
                    }
                    Spacer(minLength: 24)
                }
                // Le carrousel s'efface quand un album est en main : rien ne se superpose.
                .opacity(inspected == nil ? 1 : 0)
                .scaleEffect(inspected == nil ? 1 : 0.94)
                .blur(radius: inspected == nil ? 0 : 12)
                .allowsHitTesting(inspected == nil)

                if let inspected {
                    ShelfInspector(album: inspected, motion: motion) {
                        withAnimation(.smooth(duration: 0.45)) { self.inspected = nil }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .zIndex(2)
                }
            }
        }
        .foregroundStyle(.white)
        .onAppear {
            motion.start()
            if focusedID == nil {
                let playingAlbum = player.currentID.flatMap { library.track($0) }?.albumKey
                focusedID = playingAlbum ?? albums.first?.id
            }
        }
        .onDisappear { motion.stop() }
        .sensoryFeedback(trigger: focusedID) { _, _ in settings.haptics ? .selection : nil }
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

    private func carousel(_ albums: [AlbumInfo], width: CGFloat) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(albums) { album in
                    ShelfItem(album: album, motion: motion, isFocused: album.id == focusedID, width: itemWidth - 20)
                        .frame(width: itemWidth)
                        // Effet Cover Flow natif : calculé par iOS à chaque image, donc parfaitement fluide.
                        .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                            content
                                .rotation3DEffect(.degrees(phase.value * -55), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                                .scaleEffect(1 - abs(phase.value) * 0.16)
                                .offset(x: phase.value * -40)
                                .opacity(1 - min(0.5, abs(phase.value) * 0.32))
                        }
                        .onTapGesture {
                            if album.id == focusedID {
                                withAnimation(.smooth(duration: 0.45)) { inspected = album }
                            } else {
                                withAnimation(.smooth(duration: 0.4)) { focusedID = album.id }
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(album.title), \(album.artist)")
                        .accessibilityHint("Touche deux fois pour le prendre en main")
                        .accessibilityAddTraits(.isButton)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $focusedID)
        .safeAreaPadding(.horizontal, max(0, (width - itemWidth) / 2))
        .scrollIndicators(.hidden)
        .frame(height: 380)
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

/// Un objet du carrousel (CD ou cassette), avec son reflet au sol.
struct ShelfItem: View {
    let album: AlbumInfo
    let motion: MotionTilt
    let isFocused: Bool
    let width: CGFloat
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let format = library.format(of: album.id, default: settings.shelfFormat)
        let badges = library.badges(for: album)
        let height = format == .cd ? width / 1.13 : width / 1.58
        VStack(spacing: 3) {
            PhysicalAlbum(album: album, format: format, badges: badges,
                          lightX: isFocused ? motion.x * 0.8 : 0, lightY: isFocused ? motion.y * 0.8 : 0)
                .frame(width: width, height: height)
                .shadow(color: .black.opacity(0.6), radius: 18, y: 14)
            // Reflet sur le sol brillant (aplati en une image pour rester fluide).
            PhysicalAlbum(album: album, format: format, badges: badges, lightX: 0, lightY: 0)
                .frame(width: width, height: height)
                .drawingGroup()
                .scaleEffect(x: 1, y: -1)
                .frame(width: width, height: 70, alignment: .top)
                .clipped()
                .mask(LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                .opacity(0.5)
                .accessibilityHidden(true)
        }
        .frame(height: 340, alignment: .bottom)
        .rotation3DEffect(.degrees(isFocused ? motion.x * 6 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .rotation3DEffect(.degrees(isFocused ? -motion.y * 4 : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
        .animation(.smooth(duration: 0.4), value: format)
    }
}

/// Choisit la bonne forme physique pour un album.
struct PhysicalAlbum: View {
    let album: AlbumInfo
    let format: AlbumFormat
    var badges: [AlbumBadge] = []
    var lightX: Double = 0
    var lightY: Double = 0
    var back = false
    var spinning = false
    var progress: Double = 0

    var body: some View {
        switch format {
        case .cd:
            CDCaseView(album: album, showBack: back, lightX: lightX, lightY: lightY, animated: false, badges: badges)
        case .cassette:
            // Retournée, la face B est remise à l'endroit (sinon le texte apparaît en miroir).
            CassetteView(album: album, sideB: back, spinning: spinning, progress: progress,
                         lightX: lightX, badges: badges)
                .rotation3DEffect(.degrees(back ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        }
    }
}

/// Fond sombre avec un projecteur aux couleurs de l'album au centre.
struct ShelfBackground: View {
    let album: AlbumInfo?
    @Environment(Library.self) private var library

    var body: some View {
        let colors = album.map { library.palette(for: $0.first) } ?? Palette.defaults
        ZStack {
            Color(red: 0.03, green: 0.03, blue: 0.04)
            RadialGradient(colors: [colors[1].opacity(0.55), .clear], center: UnitPoint(x: 0.5, y: 0.38), startRadius: 10, endRadius: 420)
            RadialGradient(colors: [.white.opacity(0.08), .clear], center: UnitPoint(x: 0.5, y: 0.0), startRadius: 0, endRadius: 360)
            LinearGradient(colors: [.clear, colors[2].opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 220)
                .offset(y: 120)
                .blur(radius: 30)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: colors)
    }
}

// MARK: - Badges holographiques

struct HoloBadge: View {
    let badge: AlbumBadge
    /// Position de la lumière, de -1 à 1 : fait tourner les couleurs et glisser le reflet.
    var light: Double
    var scale: CGFloat = 1
    var showsText = false

    private var colors: [Color] {
        badge == .gold
            ? [Color(red: 1, green: 0.88, blue: 0.54), Color(red: 1, green: 0.97, blue: 0.81), Color(red: 0.83, green: 0.65, blue: 0.23),
               Color(red: 1, green: 0.91, blue: 0.66), Color(red: 0.73, green: 0.54, blue: 0.13), Color(red: 1, green: 0.88, blue: 0.54)]
            : [Color(red: 1, green: 0.6, blue: 0.84), Color(red: 0.6, green: 0.9, blue: 1), Color(red: 1, green: 0.97, blue: 0.66),
               Color(red: 0.76, green: 0.65, blue: 1), Color(red: 0.6, green: 1, blue: 0.83), Color(red: 1, green: 0.6, blue: 0.84)]
    }

    var body: some View {
        let medal = badge.isMedal && !showsText
        let shape = medal ? AnyShape(Circle()) : AnyShape(Capsule())
        HStack(spacing: 3 * scale) {
            Image(systemName: badge.symbol)
                .font(.system(size: (medal ? 12 : 7.5) * scale, weight: .heavy))
            if !medal {
                Text((showsText ? badge.short : badge.short).uppercased())
                    .font(.system(size: 7 * scale, weight: .heavy))
                    .tracking(0.6)
            }
        }
        .foregroundStyle(badge == .gold ? Color(red: 0.24, green: 0.15, blue: 0.02) : Color(red: 0.11, green: 0.06, blue: 0.19))
        .padding(.horizontal, medal ? 0 : 6 * scale)
        .padding(.vertical, medal ? 0 : 3.5 * scale)
        .frame(width: medal ? 28 * scale : nil, height: medal ? 28 * scale : nil)
        .background(shape.fill(AngularGradient(colors: colors, center: .center, angle: .degrees(light * 150))))
        .overlay(
            // Reflet qui glisse avec la lumière
            shape.fill(LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.85), location: 0.5),
                .init(color: .clear, location: 1)
            ], startPoint: UnitPoint(x: -0.6 + (light + 1) * 0.6, y: 0), endPoint: UnitPoint(x: 0.1 + (light + 1) * 0.6, y: 1)))
            .blendMode(.overlay)
        )
        .overlay(SparkleDots().clipShape(shape).blendMode(.overlay).opacity(0.7))
        .overlay(shape.stroke(.white.opacity(0.75), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.4), radius: 3, y: 1.5)
        .accessibilityLabel(badge.label)
    }
}

/// Paillettes fines pour l'effet holographique.
struct SparkleDots: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 1
            var row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 1 : 2.5
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white))
                    x += 3
                }
                y += 2.6
                row += 1
            }
        }
        .allowsHitTesting(false)
    }
}

/// Voile irisé sur la pochette des albums disque de platine.
struct HoloSheen: View {
    var light: Double

    var body: some View {
        LinearGradient(colors: [
            Color(red: 1, green: 0, blue: 0.78), Color(red: 0, green: 1, blue: 0.94), Color(red: 1, green: 0.95, blue: 0),
            Color(red: 0.63, green: 0, blue: 1), Color(red: 0, green: 1, blue: 0.55), Color(red: 1, green: 0, blue: 0.78)
        ], startPoint: UnitPoint(x: -1 + (light + 1) * 0.5, y: 0), endPoint: UnitPoint(x: 1 + (light + 1) * 0.5, y: 1))
            .blendMode(.colorDodge)
            .opacity(0.32)
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.45),
                    .init(color: .clear, location: 0.9)
                ], startPoint: UnitPoint(x: -0.3 + (light + 1) * 0.4, y: 0), endPoint: UnitPoint(x: 0.5 + (light + 1) * 0.4, y: 1))
            )
            .allowsHitTesting(false)
    }
}

// MARK: - Le boîtier CD

/// Boîtier cristal : charnière, pochette sous le plastique, reflets, badges.
struct CDCaseView: View {
    let album: AlbumInfo
    var showBack: Bool
    var lightX: Double
    var lightY: Double
    var animated = true
    var badges: [AlbumBadge] = []

    var body: some View {
        Group {
            if showBack {
                CDBackInsert(album: album, lightX: lightX)
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            } else {
                front
            }
        }
        .aspectRatio(1.13, contentMode: .fit)
    }

    private var front: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let insert = h * 0.94
            let spine = max(8, w - insert - h * 0.05)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: w * 0.025, style: .continuous)
                    .fill(Color(white: 0.06))

                ZStack(alignment: .topTrailing) {
                    ArtworkView(track: album.first, animated: animated, cornerRadius: 1)
                    if badges.contains(.platinum) { HoloSheen(light: lightX) }
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(badges) { HoloBadge(badge: $0, light: lightX, scale: w / 260) }
                    }
                    .padding(w * 0.03)
                }
                .frame(width: insert, height: insert)
                .clipped()
                .offset(x: spine + (w - spine - insert) / 2, y: (h - insert) / 2)

                CaseHinge()
                    .frame(width: spine, height: h)

                LinearGradient(stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(0.32), location: 0.45),
                    .init(color: .white.opacity(0.06), location: 0.55),
                    .init(color: .white.opacity(0), location: 1)
                ],
                startPoint: UnitPoint(x: -0.2 + lightX * 0.7, y: -0.1 + lightY * 0.3),
                endPoint: UnitPoint(x: 0.7 + lightX * 0.7, y: 1.1 + lightY * 0.3))
                    .blendMode(.screen)
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: w * 0.025, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.08), .white.opacity(0.35)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.4)
            }
        }
    }
}

/// La charnière noire du boîtier.
struct CaseHinge: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [Color(white: 0.16), Color(white: 0.05), Color(white: 0.12)]),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
            var y: CGFloat = 6
            while y < size.height - 6 {
                context.fill(Path(CGRect(x: size.width * 0.2, y: y, width: size.width * 0.6, height: 0.8)), with: .color(.white.opacity(0.08)))
                y += 4
            }
            context.fill(Path(CGRect(x: size.width - 1, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.25)))
        }
    }
}

/// Le dos du boîtier : la liste des morceaux, comme sur un vrai CD.
struct CDBackInsert: View {
    let album: AlbumInfo
    var lightX: Double
    @Environment(Library.self) private var library

    var body: some View {
        let colors = library.palette(for: album.first)
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 0) {
                spineLabel.frame(width: w * 0.06)
                VStack(alignment: .leading, spacing: 4) {
                    Text(album.title.uppercased())
                        .font(.system(size: w * 0.05, weight: .heavy))
                        .lineLimit(1)
                    Text(album.artist)
                        .font(.system(size: w * 0.035, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                    Divider().overlay(Color.white.opacity(0.3)).padding(.vertical, 2)
                    TrackListing(tracks: Array(album.tracks.prefix(16)), fontSize: w * 0.03, numberWidth: w * 0.04)
                    Spacer(minLength: 0)
                    HStack {
                        Text("Platine · \(formatDuration(album.duration))")
                            .font(.system(size: w * 0.025, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Barcode().frame(width: w * 0.16, height: w * 0.06)
                    }
                }
                .padding(w * 0.04)
                spineLabel.frame(width: w * 0.06)
            }
            .background(
                LinearGradient(colors: [colors[0], colors[1].opacity(0.85), colors[0]],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .overlay(
                LinearGradient(colors: [.clear, .white.opacity(0.25), .clear],
                               startPoint: UnitPoint(x: 0.1 - lightX * 0.6, y: 0), endPoint: UnitPoint(x: 0.6 - lightX * 0.6, y: 1))
                    .blendMode(.screen)
            )
            .clipShape(RoundedRectangle(cornerRadius: w * 0.025, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: w * 0.025, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1.2)
            )
        }
    }

    private var spineLabel: some View {
        GeometryReader { geo in
            Text("\(album.artist.uppercased()) — \(album.title.uppercased())")
                .font(.system(size: max(6, geo.size.width * 0.45), weight: .bold))
                .lineLimit(1)
                .fixedSize()
                .rotationEffect(.degrees(-90))
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(.black.opacity(0.35))
        .clipped()
    }
}

/// Liste numérotée de morceaux, utilisée au dos des CD et des cassettes.
struct TrackListing: View {
    let tracks: [Track]
    var startNumber = 1
    var fontSize: CGFloat
    var numberWidth: CGFloat

    var body: some View {
        ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
            HStack(spacing: 6) {
                Text("\(t.trackNumber > 0 ? t.trackNumber : startNumber + i)")
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: numberWidth, alignment: .trailing)
                Text(t.title).lineLimit(1)
                Spacer(minLength: 4)
                Text(formatTime(t.duration)).monospacedDigit().foregroundStyle(.white.opacity(0.55))
            }
            .font(.system(size: fontSize, weight: .medium))
        }
    }
}

struct Barcode: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let widths: [CGFloat] = [1, 2, 1, 1, 3, 1, 2, 1, 1, 2, 3, 1, 1, 2, 1, 3, 1, 1, 2, 1]
            let total = widths.reduce(0, +) * 2
            let unit = (size.width - 4) / total
            var x: CGFloat = 2
            for (i, wv) in widths.enumerated() {
                if i % 2 == 0 {
                    context.fill(Path(CGRect(x: x, y: 2, width: wv * unit, height: size.height - 4)), with: .color(.black))
                }
                x += wv * unit * 2
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Le disque

/// Le CD lui-même : surface irisée, impression de la pochette, trou central.
struct CDDisc: View {
    let album: AlbumInfo
    var spinning: Bool

    var body: some View {
        TimelineView(.animation(paused: !spinning)) { context in
            let angle = spinning ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8 * 360 : 0
            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height)
                ZStack {
                    Circle()
                        .fill(AngularGradient(colors: [
                            Color(white: 0.75), .white, Color(red: 0.6, green: 0.9, blue: 1), Color(white: 0.85),
                            Color(red: 1, green: 0.7, blue: 0.9), Color(white: 0.7), Color(red: 1, green: 0.95, blue: 0.6),
                            .white, Color(white: 0.75)
                        ], center: .center))
                    ArtworkView(track: album.first, animated: false, cornerRadius: 0)
                        .frame(width: d * 0.93, height: d * 0.93)
                        .clipShape(Circle())
                        .opacity(0.92)
                    Circle()
                        .fill(Color(white: 0.85).opacity(0.9))
                        .frame(width: d * 0.33, height: d * 0.33)
                    Circle()
                        .strokeBorder(.white.opacity(0.6), lineWidth: 1)
                        .frame(width: d * 0.33, height: d * 0.33)
                    Circle()
                        .fill(Color(red: 0.03, green: 0.03, blue: 0.04))
                        .frame(width: d * 0.15, height: d * 0.15)
                }
                .frame(width: d, height: d)
                .rotationEffect(.degrees(angle))
                .overlay(
                    Circle()
                        .fill(AngularGradient(colors: [.clear, .white.opacity(0.35), .clear, .clear, .white.opacity(0.2), .clear], center: .center))
                        .blendMode(.screen)
                        .frame(width: d, height: d)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 16, y: 10)
        .accessibilityHidden(true)
    }
}

// MARK: - La cassette

/// Cassette audio : étiquette avec la pochette, fenêtre avec les bobines qui tournent.
struct CassetteView: View {
    let album: AlbumInfo
    var sideB = false
    var spinning = false
    /// Position dans le morceau (0 à 1) : la bande passe d'une bobine à l'autre.
    var progress: Double = 0
    var lightX: Double = 0
    var badges: [AlbumBadge] = []

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                // Coque en plastique fumé
                RoundedRectangle(cornerRadius: w * 0.04, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))

                label(w: w, h: h)
                    .frame(width: w * 0.86, height: h * 0.64)
                    .clipShape(RoundedRectangle(cornerRadius: w * 0.015, style: .continuous))
                    .offset(x: w * 0.07, y: h * 0.06)

                CassetteWindow(spinning: spinning, progress: sideB ? 1 - progress : progress)
                    .frame(width: w * 0.5, height: h * 0.21)
                    .offset(x: w * 0.25, y: h * 0.34)

                CassetteBottom()
                    .fill(LinearGradient(colors: [Color(white: 0.14), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
                    .overlay(CassetteBottom().stroke(.white.opacity(0.15), lineWidth: 0.8))
                    .frame(width: w * 0.62, height: h * 0.21)
                    .offset(x: w * 0.19, y: h * 0.79)

                // Vis
                ForEach(Array(screwPositions.enumerated()), id: \.offset) { _, p in
                    Circle()
                        .fill(RadialGradient(colors: [Color(white: 0.55), Color(white: 0.2)], center: .topLeading, startRadius: 0, endRadius: w * 0.02))
                        .frame(width: w * 0.028, height: w * 0.028)
                        .offset(x: p.x * w - w * 0.014, y: p.y * h - w * 0.014)
                }

                // Reflet du plastique
                LinearGradient(stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(0.22), location: 0.45),
                    .init(color: .white.opacity(0), location: 0.7)
                ], startPoint: UnitPoint(x: -0.2 + lightX * 0.7, y: 0), endPoint: UnitPoint(x: 0.8 + lightX * 0.7, y: 1))
                    .blendMode(.screen)
                    .clipShape(RoundedRectangle(cornerRadius: w * 0.04, style: .continuous))
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: w * 0.04, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.06), .white.opacity(0.25)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
            }
        }
        .aspectRatio(1.58, contentMode: .fit)
    }

    private var screwPositions: [CGPoint] {
        [CGPoint(x: 0.04, y: 0.07), CGPoint(x: 0.96, y: 0.07), CGPoint(x: 0.04, y: 0.93), CGPoint(x: 0.96, y: 0.93), CGPoint(x: 0.5, y: 0.9)]
    }

    private func label(w: CGFloat, h: CGFloat) -> some View {
        ZStack(alignment: .top) {
            ArtworkView(track: album.first, animated: false, cornerRadius: 0)
            if badges.contains(.platinum) { HoloSheen(light: lightX) }
            VStack(spacing: 0) {
                HStack(spacing: w * 0.02) {
                    Text(sideB ? "B" : "A")
                        .font(.system(size: h * 0.1, weight: .black))
                    Text(album.title)
                        .font(.system(size: h * 0.065, weight: .bold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("C\(max(30, Int((album.duration / 60 / 15).rounded(.up)) * 15))")
                        .font(.system(size: h * 0.05, weight: .heavy))
                        .foregroundStyle(.black.opacity(0.5))
                }
                .padding(.horizontal, w * 0.03)
                .frame(height: h * 0.14)
                .background(Color(white: 0.96))
                .foregroundStyle(.black)

                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        ForEach(badges) { HoloBadge(badge: $0, light: lightX, scale: w / 300) }
                    }
                }
                .padding(w * 0.02)

                Spacer(minLength: 0)

                Text(album.artist.uppercased())
                    .font(.system(size: h * 0.05, weight: .heavy))
                    .tracking(1)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, w * 0.03)
                    .padding(.vertical, h * 0.015)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.45))
            }
        }
    }
}

/// La fenêtre de la cassette : deux bobines et la bande.
struct CassetteWindow: View {
    var spinning: Bool
    var progress: Double

    var body: some View {
        TimelineView(.animation(paused: !spinning)) { context in
            let angle = spinning ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4 * 360 : 0
            GeometryReader { geo in
                let h = geo.size.height
                let w = geo.size.width
                let left = 1 - min(1, max(0, progress))
                ZStack {
                    RoundedRectangle(cornerRadius: h * 0.25, style: .continuous)
                        .fill(Color.black.opacity(0.78))
                    // La bande entre les bobines
                    Rectangle()
                        .fill(Color(red: 0.27, green: 0.18, blue: 0.12))
                        .frame(width: w * 0.62, height: h * 0.1)
                        .offset(y: h * 0.38)
                    HStack {
                        CassetteReel(tape: left, angle: angle).frame(width: h * 0.96, height: h * 0.96)
                        Spacer()
                        CassetteReel(tape: 1 - left, angle: angle).frame(width: h * 0.96, height: h * 0.96)
                    }
                    .padding(.horizontal, h * 0.06)
                    // Vitre
                    RoundedRectangle(cornerRadius: h * 0.25, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.16), .clear, .white.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                    RoundedRectangle(cornerRadius: h * 0.25, style: .continuous)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 0.8)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct CassetteReel: View {
    /// Quantité de bande enroulée (0 à 1).
    var tape: Double
    var angle: Double

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .fill(Color(red: 0.25, green: 0.17, blue: 0.11))
                    .frame(width: d * (0.5 + 0.5 * tape), height: d * (0.5 + 0.5 * tape))
                Canvas { context, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let r = min(size.width, size.height) / 2
                    context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(Color(white: 0.92)))
                    context.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.45, y: c.y - r * 0.45, width: r * 0.9, height: r * 0.9)), with: .color(.black))
                    for k in 0..<6 {
                        let a = Double(k) / 6 * 2 * .pi
                        let p = CGPoint(x: c.x + cos(a) * r * 0.45, y: c.y + sin(a) * r * 0.45)
                        context.fill(Path(CGRect(x: p.x - r * 0.12, y: p.y - r * 0.12, width: r * 0.24, height: r * 0.24)), with: .color(Color(white: 0.92)))
                    }
                }
                .frame(width: d * 0.48, height: d * 0.48)
                .rotationEffect(.degrees(angle))
            }
            .frame(width: d, height: d)
        }
    }
}

/// Le bas de la cassette, là où passe la tête de lecture.
struct CassetteBottom: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let inset = rect.width * 0.08
        p.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Choix CD / Cassette

/// Sélecteur en verre avec une pastille qui glisse d'un format à l'autre.
struct FormatSwitch: View {
    let format: AlbumFormat
    var onChange: (AlbumFormat) -> Void
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AlbumFormat.allCases) { f in
                Button {
                    if f != format { onChange(f) }
                } label: {
                    Label(f.label, systemImage: f == .cd ? "opticaldisc" : "recordingtape")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(f == format ? Color.black : Color.white.opacity(0.8))
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background {
                            if f == format {
                                Capsule().fill(.white).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(f == format ? AccessibilityTraits.isSelected : AccessibilityTraits())
            }
        }
        .padding(4)
        .glassCapsule()
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: format)
        .sensoryFeedback(.selection, trigger: format)
    }
}

// MARK: - Prendre un album en main

/// Un CD ou une cassette en grand : fais-le tourner au doigt, zoome, retourne-le.
struct ShelfInspector: View {
    let album: AlbumInfo
    let motion: MotionTilt
    var onClose: () -> Void
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var angleX: Double = -6
    @State private var angleY: Double = 16
    @State private var startX: Double = -6
    @State private var startY: Double = 16
    @State private var dragging = false
    @State private var zoom: CGFloat = 1
    @State private var startZoom: CGFloat = 1
    @State private var discOut = false

    private var format: AlbumFormat { library.format(of: album.id, default: settings.shelfFormat) }

    private var isBack: Bool {
        cos(angleY * .pi / 180) * cos(angleX * .pi / 180) < 0
    }

    private var playingThisAlbum: Bool {
        guard let id = player.currentID else { return false }
        return album.tracks.contains { $0.id == id }
    }

    var body: some View {
        let format = self.format
        let badges = library.badges(for: album)
        let spinning = playingThisAlbum && player.isPlaying
        ZStack {
            // Fond opaque : seul l'album en main est visible.
            ZStack {
                Color(red: 0.03, green: 0.03, blue: 0.04)
                RadialGradient(colors: [library.palette(for: album.first)[1].opacity(0.35), .clear],
                               center: UnitPoint(x: 0.5, y: 0.42), startRadius: 10, endRadius: 380)
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: onClose)

            VStack(spacing: 16) {
                HStack {
                    FormatSwitch(format: format) { newValue in
                        withAnimation(.smooth(duration: 0.5)) {
                            discOut = false
                            angleX = -6
                            angleY = 16
                            startX = -6
                            startY = 16
                            library.setFormat(newValue, for: album.id)
                        }
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

                ZStack {
                    if format == .cd {
                        CDDisc(album: album, spinning: discOut && spinning)
                            .frame(width: 250, height: 250)
                            .offset(x: discOut ? 120 : 0, y: discOut ? 40 : 0)
                            .scaleEffect(discOut ? 1 : 0.9)
                            .opacity(discOut ? 1 : 0)
                            .onTapGesture { if playingThisAlbum { player.togglePlay() } else { playAlbum() } }
                    }

                    PhysicalAlbum(album: album, format: format, badges: badges,
                                  lightX: sin(angleY * .pi / 180) + motion.x * 0.5,
                                  lightY: sin(-angleX * .pi / 180) + motion.y * 0.5,
                                  back: isBack, spinning: format == .cassette && spinning,
                                  progress: playingThisAlbum && player.duration > 0 ? player.currentTime / player.duration : 0)
                        .frame(width: format == .cd ? 300 : 330)
                        .id(format)
                        .transition(.asymmetric(insertion: .scale(scale: 0.85).combined(with: .opacity),
                                                removal: .scale(scale: 1.05).combined(with: .opacity)))
                        .rotation3DEffect(.degrees(angleX), axis: (x: 1, y: 0, z: 0), perspective: 0.3)
                        .rotation3DEffect(.degrees(angleY + motion.x * 5), axis: (x: 0, y: 1, z: 0), perspective: 0.3)
                        .offset(x: discOut ? -60 : 0)
                        .shadow(color: .black.opacity(0.7), radius: 30, x: -angleY / 4, y: 24)
                        .gesture(rotateGesture.simultaneously(with: zoomGesture))
                        .onTapGesture(count: 2) { resetPose() }
                }
                .scaleEffect(zoom)
                .frame(height: 380)
                .animation(.spring(response: 0.6, dampingFraction: 0.78), value: discOut)
                .sensoryFeedback(trigger: isBack) { _, _ in settings.haptics ? .impact(weight: .light) : nil }

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
                        withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) {
                            angleY += 180
                        }
                        startY = angleY
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

    private var rotateGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                // Suit le doigt sans animation : aucune latence.
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    angleY = startY + Double(value.translation.width) * 0.55
                    angleX = max(-65, min(65, startX - Double(value.translation.height) * 0.4))
                }
            }
            .onEnded { value in
                // Élan à la vitesse réelle du geste, amorti par un ressort iOS.
                let vy = Double(value.velocity.width) * 0.55
                let vx = Double(value.velocity.height) * 0.4
                withAnimation(.interpolatingSpring(mass: 1, stiffness: 60, damping: 14, initialVelocity: 0)) {
                    angleY += vy * 0.18
                    angleX = max(-65, min(65, angleX - vx * 0.12))
                }
                startY = angleY
                startX = angleX
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in zoom = max(0.7, min(1.8, startZoom * value.magnification)) }
            .onEnded { _ in
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { zoom = max(0.8, min(1.5, zoom)) }
                startZoom = zoom
            }
    }

    private func resetPose() {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
            angleX = 0
            angleY = (angleY / 360).rounded() * 360
            zoom = 1
        }
        startX = 0
        startY = angleY
        startZoom = 1
    }

    private func playAlbum() {
        player.play(ids: album.tracks.map(\.id), shuffled: false)
    }
}

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


// MARK: - Badges holographiques

struct HoloBadge: View {
    let badge: AlbumBadge
    /// Position de la lumière, de -1 à 1 : fait tourner les couleurs et glisser le reflet.
    var light: Double
    var scale: CGFloat = 1
    var showsText = false

    private var colors: [Color] {
        badge.isGolden
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
        .foregroundStyle(badge.isGolden ? Color(red: 0.24, green: 0.15, blue: 0.02) : Color(red: 0.11, green: 0.06, blue: 0.19))
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

                // Reflets ronds du plastique moulé : un seul Canvas évite de multiplier
                // les vues et conserve un rendu léger pendant les gestes 3D.
                PlasticBubbleHighlights(lightX: lightX, lightY: lightY)
                    .opacity(0.78)
                    .allowsHitTesting(false)
                    .clipShape(RoundedRectangle(cornerRadius: w * 0.025, style: .continuous))

                RoundedRectangle(cornerRadius: w * 0.025, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.08), .white.opacity(0.35)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.4)
            }
        }
    }
}


/// Microbulles et reflets circulaires inspirés du plastique transparent d'un boîtier CD.
private struct PlasticBubbleHighlights: View {
    let lightX: Double
    let lightY: Double

    var body: some View {
        Canvas { context, size in
            let bubbles: [(CGFloat, CGFloat, CGFloat)] = [
                (0.08, 0.10, 0.035), (0.92, 0.14, 0.025), (0.12, 0.88, 0.022),
                (0.89, 0.84, 0.042), (0.50, 0.035, 0.018), (0.045, 0.52, 0.014),
                (0.96, 0.53, 0.017), (0.72, 0.94, 0.016)
            ]
            for (x, y, radius) in bubbles {
                let r = max(2, size.width * radius)
                let center = CGPoint(x: size.width * x + CGFloat(lightX) * r * 0.22,
                                     y: size.height * y + CGFloat(lightY) * r * 0.22)
                let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.24)), lineWidth: max(0.6, r * 0.055))
                let shine = CGRect(x: center.x - r * 0.48, y: center.y - r * 0.55, width: r * 0.65, height: r * 0.30)
                context.fill(Path(ellipseIn: shine), with: .color(.white.opacity(0.18)))
            }
            var sweep = Path()
            sweep.move(to: CGPoint(x: size.width * 0.08, y: size.height * 0.02))
            sweep.addQuadCurve(to: CGPoint(x: size.width * 0.94, y: size.height * 0.12),
                               control: CGPoint(x: size.width * 0.48, y: size.height * 0.18))
            context.stroke(sweep, with: .color(.white.opacity(0.22)), lineWidth: max(1, size.width * 0.004))
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
        let colors = library.palette(for: album.cover)
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
            ForEach(AlbumFormat.choosable) { f in
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


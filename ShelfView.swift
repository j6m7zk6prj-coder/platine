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
                    ArtworkView(track: album.cover, animated: animated, cornerRadius: 1)
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

/// Le dos du boîtier, comme sur un vrai CD : liste des morceaux, durée totale, mentions ℗ / ©,
/// numéro de catalogue et un vrai code-barres EAN-13 (unique pour chaque album).
struct CDBackInsert: View {
    let album: AlbumInfo
    var lightX: Double
    @Environment(Library.self) private var library

    /// L'année de sortie ; à défaut, l'année où l'album est entré dans la bibliothèque.
    private var year: Int {
        if album.year > 0 { return album.year }
        let added = album.tracks.map(\.addedAt).min() ?? Date()
        return Calendar.current.component(.year, from: added)
    }

    private var code: EAN13 { EAN13(seed: album.id) }
    private var catalog: String { "PLT \(code.digits.dropFirst(7).prefix(5).map(String.init).joined())-\(code.digits[12])" }

    var body: some View {
        let colors = library.palette(for: album.cover)
        let art = library.image(for: album.cover)
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let tracks = Array(album.tracks.prefix(24))
            let twoColumns = tracks.count > 11
            let half = Int((Double(tracks.count) / 2).rounded(.up))
            let fs = w * (twoColumns ? 0.0215 : 0.026)
            HStack(spacing: 0) {
                spine(w: w, h: h)
                VStack(alignment: .leading, spacing: 0) {
                    // En-tête : artiste et titre.
                    Text(album.artist.uppercased())
                        .font(.system(size: w * 0.026, weight: .semibold))
                        .tracking(w * 0.004)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                    Text(album.title)
                        .font(.system(size: w * 0.048, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.bottom, h * 0.025)

                    // Liste des morceaux.
                    HStack(alignment: .top, spacing: w * 0.04) {
                        VStack(alignment: .leading, spacing: fs * 0.42) {
                            TrackListing(tracks: Array(tracks.prefix(twoColumns ? half : tracks.count)),
                                         fontSize: fs, numberWidth: fs * 1.4)
                        }
                        if twoColumns {
                            VStack(alignment: .leading, spacing: fs * 0.42) {
                                TrackListing(tracks: Array(tracks.dropFirst(half)), startNumber: half + 1,
                                             fontSize: fs, numberWidth: fs * 1.4)
                            }
                        }
                    }
                    if album.tracks.count > tracks.count {
                        Text("+ \(album.tracks.count - tracks.count) titres")
                            .font(.system(size: fs, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                            .padding(.top, 2)
                    }
                    Text("Durée totale \(formatDuration(album.duration))")
                        .font(.system(size: fs * 0.95, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, h * 0.02)

                    Spacer(minLength: 0)

                    // Pied : mentions légales à gauche, code-barres à droite.
                    HStack(alignment: .bottom, spacing: w * 0.03) {
                        VStack(alignment: .leading, spacing: w * 0.006) {
                            HStack(spacing: w * 0.012) {
                                badge("STÉRÉO", w: w)
                                badge("DDD", w: w)
                                Text(catalog)
                                    .font(.system(size: w * 0.017, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            Text("℗ \(String(year)) Platine Records · © \(String(year)) Platine Records")
                                .font(.system(size: w * 0.0165, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.8))
                            Text("Tous droits du producteur phonographique et du propriétaire de l’œuvre enregistrée réservés. Sauf autorisation, la duplication, la location, le prêt, l’utilisation de ce disque pour exécution publique et radiodiffusion sont interdits.")
                                .font(.system(size: w * 0.0118))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Fabriqué dans l’UE · Distribué par Platine · www.platine.example")
                                .font(.system(size: w * 0.0118, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer(minLength: 0)
                        EAN13View(code: code)
                            .frame(width: w * 0.2, height: w * 0.112)
                    }
                }
                .padding(.horizontal, w * 0.04)
                .padding(.vertical, h * 0.05)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                spine(w: w, h: h)
            }
            .foregroundStyle(.white)
            .background {
                ZStack {
                    LinearGradient(colors: [colors[0], colors[1].opacity(0.9), colors[0]],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    // La pochette, très floue, comme le fond imprimé d'un vrai livret.
                    if let art {
                        Image(uiImage: art).resizable().scaledToFill()
                            .frame(width: w, height: h).clipped()
                            .blur(radius: w * 0.05)
                            .opacity(0.55)
                    }
                    LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.35), .black.opacity(0.7)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .overlay(
                LinearGradient(colors: [.clear, .white.opacity(0.18), .clear],
                               startPoint: UnitPoint(x: 0.1 - lightX * 0.6, y: 0), endPoint: UnitPoint(x: 0.6 - lightX * 0.6, y: 1))
                    .blendMode(.screen)
            )
            .clipped()
        }
    }

    private func badge(_ text: String, w: CGFloat) -> some View {
        Text(text)
            .font(.system(size: w * 0.0135, weight: .heavy))
            .padding(.horizontal, w * 0.006)
            .padding(.vertical, w * 0.002)
            .overlay(RoundedRectangle(cornerRadius: w * 0.003).strokeBorder(.white.opacity(0.8), lineWidth: 0.8))
            .foregroundStyle(.white.opacity(0.85))
    }

    /// Tranche latérale : artiste — titre, puis le numéro de catalogue, lus de haut en bas.
    private func spine(w: CGFloat, h: CGFloat) -> some View {
        let width = w * 0.045
        return HStack(spacing: width * 0.5) {
            Text(album.artist.uppercased()).font(.system(size: width * 0.42, weight: .heavy))
            Text(album.title).font(.system(size: width * 0.42, weight: .medium)).opacity(0.85)
            Spacer(minLength: 0)
            Text(catalog).font(.system(size: width * 0.32, weight: .semibold, design: .monospaced)).opacity(0.7)
        }
        .lineLimit(1)
        .padding(.horizontal, h * 0.04)
        .frame(width: h, height: width)
        .rotationEffect(.degrees(90))
        .frame(width: width, height: h)
        .background(.black.opacity(0.45))
        .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.12)).frame(width: 0.6) }
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.12)).frame(width: 0.6) }
        .clipped()
    }
}

/// Code EAN-13 valide (avec sa clé de contrôle), toujours le même pour un album donné.
struct EAN13 {
    let digits: [Int]

    init(seed: String) {
        // Empreinte FNV-1a : stable d'un lancement à l'autre (contrairement à hashValue).
        var hash: UInt64 = 0xcbf29ce484222325
        for b in seed.utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        var d = [3, 7, 0, 1, 2]                       // préfixe et « éditeur » fictifs
        for _ in 0..<7 { d.append(Int(hash % 10)); hash /= 10 }
        let sum = d.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
        d.append((10 - sum % 10) % 10)
        digits = d
    }

    private static let l = ["0001101", "0011001", "0010011", "0111101", "0100011",
                            "0110001", "0101111", "0111011", "0110111", "0001011"]
    private static let parity = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG",
                                 "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]

    private static func r(_ d: Int) -> String { String(l[d].map { $0 == "0" ? "1" : "0" }) }
    private static func g(_ d: Int) -> String { String(r(d).reversed()) }

    /// Les 95 modules : `bar` = barre noire, `tall` = barres de garde (plus longues).
    var modules: [(bar: Bool, tall: Bool)] {
        var out: [(bar: Bool, tall: Bool)] = []
        func add(_ s: String, _ isGuard: Bool) { for c in s { out.append((bar: c == "1", tall: isGuard)) } }
        add("101", true)
        let p = Array(Self.parity[digits[0]])
        for i in 1...6 { add(p[i - 1] == "L" ? Self.l[digits[i]] : Self.g(digits[i]), false) }
        add("01010", true)
        for i in 7...12 { add(Self.r(digits[i]), false) }
        add("101", true)
        return out
    }
}

struct EAN13View: View {
    let code: EAN13

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let total: CGFloat = 95 + 11 + 7
            let unit = size.width / total
            let left = 11 * unit
            let textH = size.height * 0.2
            let top = size.height * 0.07
            let barBottom = size.height - textH - size.height * 0.04
            for (i, m) in code.modules.enumerated() where m.bar {
                let bottom = m.tall ? barBottom + textH * 0.55 : barBottom
                context.fill(Path(CGRect(x: left + CGFloat(i) * unit, y: top, width: unit, height: bottom - top)),
                             with: .color(.black))
            }
            let font = Font.system(size: textH * 0.95, weight: .medium, design: .monospaced)
            let y = barBottom + textH * 0.55
            func digit(_ d: Int, _ x: CGFloat) {
                context.draw(Text(String(d)).font(font).foregroundStyle(.black), at: CGPoint(x: x, y: y))
            }
            digit(code.digits[0], left - 4.5 * unit)
            for i in 1...6 { digit(code.digits[i], left + (3 + 7 * CGFloat(i - 1) + 3.5) * unit) }
            for i in 7...12 { digit(code.digits[i], left + (50 + 7 * CGFloat(i - 7) + 3.5) * unit) }
        }
        .accessibilityLabel("Code-barres \(code.digits.map(String.init).joined())")
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
                    ArtworkView(track: album.cover, animated: false, cornerRadius: 0)
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
            ArtworkView(track: album.cover, animated: false, cornerRadius: 0)
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


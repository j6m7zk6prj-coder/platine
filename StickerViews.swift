import SwiftUI
import PhotosUI

// MARK: - Stickers faits à partir de tes images

/// Une image transformée en sticker brillant : holographique, argent, or, or rose ou couleurs d'origine.
struct FoilSticker: View {
    let image: UIImage?
    let finish: StickerFinish
    var round = true
    /// Position de la lumière, de -1 à 1 : fait tourner les reflets.
    var light: Double = -0.3
    var size: CGFloat = 44

    private static let holo: [Color] = [
        Color(red: 1, green: 0.55, blue: 0.82), Color(red: 0.55, green: 0.88, blue: 1),
        Color(red: 1, green: 0.97, blue: 0.6), Color(red: 0.72, green: 0.6, blue: 1),
        Color(red: 0.55, green: 1, blue: 0.8), Color(red: 1, green: 0.55, blue: 0.82)
    ]
    private static let gold: [Color] = [
        Color(red: 0.72, green: 0.52, blue: 0.14), Color(red: 1, green: 0.9, blue: 0.6),
        Color(red: 0.85, green: 0.66, blue: 0.25), Color(red: 1, green: 0.95, blue: 0.75),
        Color(red: 0.7, green: 0.5, blue: 0.12)
    ]
    private static let rose: [Color] = [
        Color(red: 0.75, green: 0.45, blue: 0.42), Color(red: 1, green: 0.84, blue: 0.8),
        Color(red: 0.88, green: 0.6, blue: 0.56), Color(red: 1, green: 0.9, blue: 0.86),
        Color(red: 0.72, green: 0.42, blue: 0.4)
    ]

    var body: some View {
        let shape = round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        ZStack {
            if let image {
                foil(Image(uiImage: image).resizable().scaledToFill())
            } else {
                Color.gray
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        // Reflet qui glisse avec la lumière.
        .overlay(
            shape.fill(LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.75), location: 0.5),
                .init(color: .clear, location: 1)
            ], startPoint: UnitPoint(x: -0.6 + (light + 1) * 0.6, y: 0), endPoint: UnitPoint(x: 0.1 + (light + 1) * 0.6, y: 1)))
            .blendMode(.overlay)
        )
        .overlay(SparkleDots().clipShape(shape).blendMode(.overlay).opacity(finish == .color ? 0.35 : 0.65))
        // Liseré blanc de découpe, comme un vrai sticker.
        .overlay(shape.stroke(Color.white.opacity(0.92), lineWidth: max(1.5, size * 0.05)))
        .shadow(color: .black.opacity(0.4), radius: size * 0.08, y: size * 0.04)
    }

    @ViewBuilder private func foil<V: View>(_ picture: V) -> some View {
        let angle = Angle.degrees(light * 150)
        switch finish {
        case .color:
            picture
        case .holo:
            picture.grayscale(1).contrast(1.15)
                .overlay(AngularGradient(colors: Self.holo, center: .center, angle: angle).blendMode(.color))
        case .silver:
            picture.grayscale(1).contrast(1.25).brightness(0.06)
                .overlay(LinearGradient(colors: [Color(white: 0.55), Color(white: 1), Color(white: 0.7)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing).blendMode(.softLight))
        case .gold:
            picture.grayscale(1).contrast(1.15)
                .overlay(AngularGradient(colors: Self.gold, center: .center, angle: angle).blendMode(.color))
                .overlay(LinearGradient(colors: Self.gold, startPoint: .topLeading, endPoint: .bottomTrailing).blendMode(.softLight))
        case .rose:
            picture.grayscale(1).contrast(1.15)
                .overlay(AngularGradient(colors: Self.rose, center: .center, angle: angle).blendMode(.color))
                .overlay(LinearGradient(colors: Self.rose, startPoint: .topLeading, endPoint: .bottomTrailing).blendMode(.softLight))
        }
    }
}

/// Un de tes stickers, tel qu'enregistré.
struct CustomStickerBadge: View {
    let sticker: CustomSticker
    var light: Double = -0.3
    var size: CGFloat = 44
    @Environment(Library.self) private var library

    var body: some View {
        FoilSticker(image: library.customStickerImage(sticker), finish: sticker.finish,
                    round: sticker.round, light: light, size: size)
            .accessibilityLabel("Sticker " + sticker.finish.label)
    }
}

/// Tous les stickers d'un album, empilés (sert à les poser sur les boîtiers en 3D).
struct StickerStack: View {
    let album: AlbumInfo
    let badges: [AlbumBadge]
    var scale: CGFloat = 1
    @Environment(Library.self) private var library

    var body: some View {
        VStack(alignment: .trailing, spacing: 6 * scale) {
            ForEach(badges) { HoloBadge(badge: $0, light: -0.3, scale: scale) }
            ForEach(library.customStickers(for: album.id)) { CustomStickerBadge(sticker: $0, size: 44 * scale) }
        }
    }
}

// MARK: - Créer un sticker

/// Choix de la finition et de la forme, avec un aperçu qui brille.
struct StickerFinishSheet: View {
    let image: UIImage
    var onCreate: (StickerFinish, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var finish: StickerFinish = .holo
    @State private var round = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 26) {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let light = sin(context.date.timeIntervalSinceReferenceDate * 0.9)
                    FoilSticker(image: image, finish: finish, round: round, light: light, size: 200)
                }
                .frame(height: 220)
                .padding(.top, 20)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                    ForEach(StickerFinish.allCases) { f in
                        let on = f == finish
                        Button {
                            withAnimation(.smooth(duration: 0.3)) { finish = f }
                        } label: {
                            VStack(spacing: 8) {
                                FoilSticker(image: image, finish: f, round: round, size: 46)
                                Text(f.label).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(on ? 0.16 : 0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.white.opacity(on ? 0.8 : 0.08), lineWidth: on ? 1.5 : 1))
                        }
                        .buttonStyle(PressStyle(circle: false))
                        .sensoryFeedback(.selection, trigger: on)
                    }
                }
                .padding(.horizontal, 20)

                Picker("Forme", selection: $round) {
                    Text("Rond").tag(true)
                    Text("Carré arrondi").tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)

                Spacer(minLength: 0)

                Button {
                    onCreate(finish, round)
                    dismiss()
                } label: {
                    Text("Créer le sticker")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .navigationTitle("Nouveau sticker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Section « Mes stickers » de la feuille des stickers : créer, poser, retirer, supprimer.
struct MyStickersSection: View {
    let album: AlbumInfo
    var light: Double
    @Environment(Library.self) private var library
    @State private var photoItem: PhotosPickerItem?
    @State private var cropping: CropSource?
    @State private var finishing: CropSource?

    var body: some View {
        let chosen = Set(library.stickerKeys(for: album.id))
        VStack(alignment: .leading, spacing: 12) {
            Text("Mes stickers").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 12)], spacing: 12) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    VStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.title2.weight(.semibold))
                            .frame(width: 52, height: 52)
                            .background(Circle().strokeBorder(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                        Text("Depuis une image").font(.caption2.weight(.semibold)).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                ForEach(library.customStickers) { sticker in
                    let on = chosen.contains(sticker.key)
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            library.toggleCustomSticker(sticker, for: album.id)
                        }
                    } label: {
                        VStack(spacing: 8) {
                            CustomStickerBadge(sticker: sticker, light: light, size: 52)
                            Text(sticker.finish.label).font(.caption2.weight(.semibold)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(on ? 0.16 : 0.0)))
                        .overlay(alignment: .topTrailing) {
                            if on {
                                Image(systemName: "checkmark.circle.fill").padding(4)
                            }
                        }
                    }
                    .buttonStyle(PressStyle(circle: false))
                    .contextMenu {
                        Button("Supprimer ce sticker", systemImage: "trash", role: .destructive) {
                            library.deleteCustomSticker(sticker)
                        }
                    }
                }
            }
            Text("Choisis une image, recadre-la, puis choisis sa finition. Appui long sur un de tes stickers pour le supprimer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    cropping = CropSource(image: img)
                }
                photoItem = nil
            }
        }
        .fullScreenCover(item: $cropping) { source in
            CoverCropper(image: source.image, aspect: 1, title: "Sticker") { cropped in
                // On laisse le recadrage se fermer avant d'ouvrir le choix de la finition.
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    finishing = CropSource(image: cropped)
                }
            }
        }
        .sheet(item: $finishing) { source in
            StickerFinishSheet(image: source.image) { finish, round in
                if let sticker = library.addCustomSticker(source.image, finish: finish, round: round) {
                    library.toggleCustomSticker(sticker, for: album.id)
                }
            }
            .presentationDetents([.large])
        }
    }
}


// MARK: - Stickers placés librement sur la jaquette

/// Un sticker (gagné, choisi ou à toi), dessiné dans un carré de la taille donnée.
struct AnySticker: View {
    let key: String
    let size: CGFloat
    var light: Double = -0.3
    /// Coin en bas à droite soulevé, comme un sticker qui se décolle.
    var peeled = false
    @Environment(Library.self) private var library

    var body: some View {
        Group {
            if let badge = AlbumBadge(rawValue: key) {
                HoloBadge(badge: badge, light: light, scale: size / 30)
            } else if let sticker = library.customStickers.first(where: { $0.key == key }) {
                CustomStickerBadge(sticker: sticker, light: light, size: size)
            }
        }
        .frame(width: size, height: size)
        .mask {
            if peeled {
                PeelMask().fill(style: FillStyle(eoFill: false))
            } else {
                Rectangle()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if peeled {
                // Le revers du coin : papier blanc, ombré.
                PeelCurl()
                    .fill(LinearGradient(colors: [Color(white: 0.98), Color(white: 0.78)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: size * 0.3, height: size * 0.3)
                    .shadow(color: .black.opacity(0.45), radius: size * 0.04, x: -size * 0.02, y: -size * 0.02)
                    .offset(x: -size * 0.06, y: -size * 0.06)
            }
        }
    }
}

/// Le sticker sans son coin en bas à droite.
struct PeelMask: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cut = rect.width * 0.36
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cut))
        p.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Le coin replié.
struct PeelCurl: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.minY + rect.height * 0.15))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Tous les stickers d'un album, chacun à sa place sur une jaquette de la taille donnée.
struct PlacedStickers: View {
    let album: AlbumInfo
    let badges: [AlbumBadge]
    let size: CGSize
    @Environment(Library.self) private var library

    var body: some View {
        let keys = library.stickerOrder(for: album, badges: badges)
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(keys.enumerated()), id: \.element) { index, key in
                let p = library.placement(key, index: index, albumID: album.id)
                AnySticker(key: key, size: size.width * 0.2 * p.scale, peeled: p.peeled)
                    .rotationEffect(.degrees(p.rotation))
                    .position(x: size.width * p.x, y: size.height * p.y)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Écran pour placer les stickers où tu veux : glisse pour déplacer, pince pour la taille,
/// tourne avec deux doigts pour l'angle.
struct StickerPlacer: View {
    let album: AlbumInfo
    let badges: [AlbumBadge]
    /// Image de fond : la pochette (CD) ou la jaquette (jeu).
    let background: UIImage?
    /// Largeur ÷ hauteur de la jaquette.
    let aspect: CGFloat
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var placements: [String: StickerPlacement] = [:]
    @State private var dragStart: [String: StickerPlacement] = [:]
    @State private var selected: String?

    var body: some View {
        let keys = library.stickerOrder(for: album, badges: badges)
        NavigationStack {
            VStack(spacing: 18) {
                GeometryReader { geo in
                    let w = min(geo.size.width - 40, (geo.size.height - 20) * aspect)
                    let size = CGSize(width: w, height: w / aspect)
                    ZStack(alignment: .topLeading) {
                        Group {
                            if let background {
                                Image(uiImage: background).resizable().scaledToFill()
                            } else {
                                Color(white: 0.15)
                            }
                        }
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        ForEach(Array(keys.enumerated()), id: \.element) { index, key in
                            let p = placements[key] ?? library.placement(key, index: index, albumID: album.id)
                            AnySticker(key: key, size: size.width * 0.2 * p.scale, peeled: p.peeled)
                                .overlay {
                                    if selected == key {
                                        Circle().strokeBorder(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                                            .padding(-6)
                                    }
                                }
                                .rotationEffect(.degrees(p.rotation))
                                .position(x: size.width * p.x, y: size.height * p.y)
                                .gesture(drag(key, index: index, size: size)
                                    .simultaneously(with: pinch(key, index: index))
                                    .simultaneously(with: twist(key, index: index)))
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let key = selected, let index = keys.firstIndex(of: key) {
                    selectedPanel(key, index: index)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Text("Touche un sticker pour le régler · glisse pour le déplacer · pince pour l’agrandir · tourne avec deux doigts")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Button("Remettre en place") {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        placements = [:]
                        for (i, key) in keys.enumerated() { placements[key] = .standard(i) }
                    }
                }
                .padding(.bottom, 10)
            }
            .navigationTitle("Placer les stickers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        var map: [String: StickerPlacement] = [:]
                        for (i, key) in keys.enumerated() {
                            map[key] = placements[key] ?? library.placement(key, index: i, albumID: album.id)
                        }
                        library.setPlacements(map, for: album.id)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    /// Réglages du sticker touché : taille, coin décollé, dupliquer, retirer.
    private func selectedPanel(_ key: String, index: Int) -> some View {
        let p = current(key, index)
        let custom = library.customStickers.first { $0.key == key }
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: Binding(get: { p.scale }, set: { v in
                    var q = current(key, index)
                    q.scale = v
                    placements[key] = q
                }), in: 0.4...3)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    var q = current(key, index)
                    q.peeled.toggle()
                    placements[key] = q
                } label: {
                    Label(p.peeled ? "Recoller" : "Décoller un coin", systemImage: "arrow.up.right.and.arrow.down.left")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                if let custom {
                    Button {
                        library.duplicateCustomSticker(custom, for: album.id)
                    } label: {
                        Label("Dupliquer", systemImage: "plus.square.on.square").font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
                Button(role: .destructive) {
                    library.removeSticker(key, from: album.id)
                    placements[key] = nil
                    selected = nil
                } label: {
                    Label("Retirer", systemImage: "trash").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 20)
    }

    private func current(_ key: String, _ index: Int) -> StickerPlacement {
        placements[key] ?? library.placement(key, index: index, albumID: album.id)
    }

    private func begin(_ key: String, _ index: Int) -> StickerPlacement {
        if let start = dragStart[key] { return start }
        let start = current(key, index)
        dragStart[key] = start
        selected = key
        return start
    }

    private func drag(_ key: String, index: Int, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let start = begin(key, index)
                var p = current(key, index)
                p.x = min(1, max(0, start.x + Double(g.translation.width / size.width)))
                p.y = min(1, max(0, start.y + Double(g.translation.height / size.height)))
                placements[key] = p
            }
            .onEnded { _ in dragStart[key] = nil }
    }

    private func pinch(_ key: String, index: Int) -> some Gesture {
        MagnifyGesture()
            .onChanged { g in
                let start = begin(key, index)
                var p = current(key, index)
                p.scale = min(3, max(0.4, start.scale * Double(g.magnification)))
                placements[key] = p
            }
            .onEnded { _ in dragStart[key] = nil }
    }

    private func twist(_ key: String, index: Int) -> some Gesture {
        RotateGesture()
            .onChanged { g in
                let start = begin(key, index)
                var p = current(key, index)
                p.rotation = start.rotation + g.rotation.degrees
                placements[key] = p
            }
            .onEnded { _ in dragStart[key] = nil }
    }
}


// MARK: - Personnaliser le boîtier

/// Jaquette, dos, tranche et disque : chaque image peut être remplacée par la tienne, recadrée au bon format.
struct CaseCustomizer: View {
    let album: AlbumInfo
    /// Nom du jeu (boîtier de jeu) ; nil pour un CD (seul le disque se personnalise).
    let game: String?
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var target: Slot?
    @State private var photoItem: PhotosPickerItem?
    @State private var cropping: CropSource?

    enum Slot: String, Identifiable {
        case wrap, cover, back, spine, front, disc
        var id: String { rawValue }
        var title: String {
            switch self {
            case .wrap: return "Jaquette complète"
            case .cover: return "Jaquette"
            case .back: return "Dos du boîtier"
            case .spine: return "Tranche"
            case .front: return "Pochette avant"
            case .disc: return "Disque"
            }
        }
        var detail: String {
            switch self {
            case .wrap: return "Dos + tranche + face en une image : tout se place d’un coup"
            case .cover: return "La face avant, sous le film"
            case .back: return "L’arrière du boîtier"
            case .spine: return "Le côté, visible sur l’étagère"
            case .front: return "L’image carrée sous le couvercle du boîtier"
            case .disc: return "Recadrée en cercle, comme une photo de profil"
            }
        }
        var symbol: String {
            switch self {
            case .wrap: return "book.pages"
            case .cover: return "rectangle.portrait"
            case .back: return "rectangle.portrait.on.rectangle.portrait"
            case .spine: return "rectangle.split.3x1"
            case .front: return "square"
            case .disc: return "opticaldisc"
            }
        }
    }

    private var slots: [Slot] { game == nil ? [.front, .disc] : [.wrap, .cover, .back, .spine, .disc] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(slots) { slot in row(slot) }
                } footer: {
                    Text("Le boîtier au-dessus se met à jour dès que tu valides une image.")
                }
            }
            .navigationTitle("Personnaliser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    cropping = CropSource(image: img)
                }
                photoItem = nil
            }
        }
        .fullScreenCover(item: $cropping) { source in
            CoverCropper(image: source.image, aspect: aspect(target ?? .cover),
                         title: (target ?? .cover).title, round: target == .disc) { cropped in
                save(cropped, in: target ?? .cover)
            }
        }
    }

    private func row(_ slot: Slot) -> some View {
        HStack(spacing: 14) {
            thumbnail(slot)
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title).font(.body.weight(.semibold))
                Text(isCustom(slot) ? "Ton image" : slot.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isCustom(slot) {
                Button {
                    reset(slot)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remettre l’image d’origine")
            }
            PhotosPicker(selection: Binding(get: { nil }, set: { item in
                target = slot
                photoItem = item
            }), matching: .images) {
                Text("Changer").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func thumbnail(_ slot: Slot) -> some View {
        let img = current(slot)
        let shape = slot == .disc ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        ZStack {
            Color(white: 0.18)
            if let img {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: slot.symbol).foregroundStyle(.secondary)
            }
        }
        .frame(width: thumbWidth(slot), height: 52)
        .clipShape(shape)
    }

    private func thumbWidth(_ slot: Slot) -> CGFloat {
        switch slot {
        case .spine: return 10
        case .disc: return 52
        case .wrap: return 92
        default: return 45
        }
    }

    private func current(_ slot: Slot) -> UIImage? {
        switch slot {
        case .wrap: return nil
        case .cover: return game.flatMap { library.gameCoverImage($0) }
        case .back: return game.flatMap { library.extraImage("back", $0) }
        case .spine: return game.flatMap { library.extraImage("spine", $0) }
        case .front: return library.extraImage("front", album.id)
        case .disc: return library.extraImage("disc", album.id)
        }
    }

    private func isCustom(_ slot: Slot) -> Bool {
        if slot == .wrap { return [Slot.cover, .back, .spine].contains { current($0) != nil } }
        return current(slot) != nil
    }

    /// Une bande verticale de l'image, de `from` à `to` (fractions de la largeur).
    static func slice(_ image: UIImage, _ from: CGFloat, _ to: CGFloat) -> UIImage {
        let w = image.size.width, h = image.size.height
        let rect = CGRect(x: w * from, y: 0, width: w * (to - from), height: h)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            image.draw(at: CGPoint(x: -rect.minX, y: 0))
        }
    }

    private func aspect(_ slot: Slot) -> CGFloat {
        let insert = Physical.insert
        switch slot {
        case .wrap: return Physical.wrapAspect
        case .cover, .back: return insert.width / insert.height
        case .spine: return Physical.insertSpine / insert.height
        case .front, .disc: return 1
        }
    }

    private func save(_ image: UIImage, in slot: Slot) {
        switch slot {
        case .wrap:
            // Découpe selon les vraies proportions : dos 128 mm | tranche 14 mm | face 128 mm.
            guard let game else { return }
            let total = Physical.insert.width * 2 + Physical.insertSpine
            let backEnd = Physical.insert.width / total
            let spineEnd = (Physical.insert.width + Physical.insertSpine) / total
            library.setExtraImage(Self.slice(image, 0, backEnd), kind: "back", key: game)
            library.setExtraImage(Self.slice(image, backEnd, spineEnd), kind: "spine", key: game)
            library.setGameCover(Self.slice(image, spineEnd, 1), for: game)
        case .cover: if let game { library.setGameCover(image, for: game) }
        case .back: if let game { library.setExtraImage(image, kind: "back", key: game) }
        case .spine: if let game { library.setExtraImage(image, kind: "spine", key: game) }
        case .front: library.setExtraImage(image, kind: "front", key: album.id)
        case .disc: library.setExtraImage(image, kind: "disc", key: album.id)
        }
    }

    private func reset(_ slot: Slot) {
        switch slot {
        case .wrap:
            if let game {
                library.resetGameCover(game)
                library.resetExtraImage("back", game)
                library.resetExtraImage("spine", game)
            }
        case .cover: if let game { library.resetGameCover(game) }
        case .back: if let game { library.resetExtraImage("back", game) }
        case .spine: if let game { library.resetExtraImage("spine", game) }
        case .front: library.resetExtraImage("front", album.id)
        case .disc: library.resetExtraImage("disc", album.id)
        }
    }
}

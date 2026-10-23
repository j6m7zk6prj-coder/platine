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
            CoverCropper(image: source.image, aspect: 1) { cropped in
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

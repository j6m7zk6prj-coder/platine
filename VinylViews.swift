import SwiftUI

// MARK: - Dos de la pochette du vinyle

/// Le dos d'un 33 tours : faces A et B (C et D pour un double), durées, ℗ / ©, catalogue,
/// « 33⅓ tours/min », mentions légales et code-barres EAN-13.
struct VinylBackInsert: View {
    let album: AlbumInfo
    let discs: Int
    let catalog: String
    @Environment(Library.self) private var library

    private var year: Int {
        if album.year > 0 { return album.year }
        let added = album.tracks.map(\.addedAt).min() ?? Date()
        return Calendar.current.component(.year, from: added)
    }

    var body: some View {
        let colors = library.palette(for: album.cover)
        let art = library.image(for: album.cover)
        let sides = VinylLayout.sides(album, discs: discs)
        GeometryReader { geo in
            let w = geo.size.width
            let fs = w * (album.tracks.count > 16 ? 0.0175 : 0.021)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.artist.uppercased())
                            .font(.system(size: w * 0.026, weight: .semibold))
                            .tracking(w * 0.005)
                            .foregroundStyle(.white.opacity(0.75))
                        Text(album.title)
                            .font(.system(size: w * 0.05, weight: .bold))
                            .minimumScaleFactor(0.6)
                    }
                    .lineLimit(1)
                    Spacer()
                    Text(discs > 1 ? "2 × LP" : "LP")
                        .font(.system(size: w * 0.03, weight: .black))
                        .padding(.horizontal, w * 0.012)
                        .overlay(RoundedRectangle(cornerRadius: w * 0.006).strokeBorder(.white.opacity(0.8), lineWidth: 1))
                }
                .padding(.bottom, w * 0.035)

                // Une colonne par face.
                HStack(alignment: .top, spacing: w * 0.04) {
                    ForEach(Array(sides.enumerated()), id: \.offset) { _, side in
                        VStack(alignment: .leading, spacing: fs * 0.45) {
                            HStack {
                                Text("FACE \(side.letter)").font(.system(size: fs * 1.05, weight: .heavy)).tracking(1.5)
                                Spacer(minLength: 2)
                                Text(formatDuration(side.duration)).font(.system(size: fs * 0.9, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            Rectangle().fill(.white.opacity(0.35)).frame(height: 0.8)
                            if side.tracks.isEmpty {
                                Text("—").font(.system(size: fs)).foregroundStyle(.white.opacity(0.5))
                            }
                            ForEach(Array(side.tracks.prefix(12).enumerated()), id: \.offset) { i, t in
                                HStack(spacing: 4) {
                                    Text("\(side.letter)\(i + 1)").monospacedDigit().foregroundStyle(.white.opacity(0.55))
                                        .frame(width: fs * 1.8, alignment: .leading)
                                    Text(t.title).lineLimit(1)
                                    Spacer(minLength: 2)
                                    Text(formatTime(t.duration)).monospacedDigit().foregroundStyle(.white.opacity(0.55))
                                }
                                .font(.system(size: fs, weight: .medium))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Spacer(minLength: 0)

                HStack(alignment: .bottom, spacing: w * 0.03) {
                    VStack(alignment: .leading, spacing: w * 0.006) {
                        HStack(spacing: w * 0.012) {
                            badge("33⅓ TOURS/MIN", w)
                            badge("STÉRÉO", w)
                            badge("180 G", w)
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
                        Text("Fabriqué dans l’UE · Pressé sur vinyle 180 g · Distribué par Platine")
                            .font(.system(size: w * 0.0118, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer(minLength: 0)
                    EAN13View(code: EAN13(seed: album.id))
                        .frame(width: w * 0.2, height: w * 0.112)
                }
            }
            .padding(w * 0.055)
            .foregroundStyle(.white)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .background {
                ZStack {
                    LinearGradient(colors: [colors[0], colors[1].opacity(0.9), colors[0]],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let art {
                        Image(uiImage: art).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height).clipped()
                            .blur(radius: w * 0.05)
                            .opacity(0.55)
                    }
                    LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.4), .black.opacity(0.72)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .clipped()
        }
    }

    private func badge(_ text: String, _ w: CGFloat) -> some View {
        Text(text)
            .font(.system(size: w * 0.0135, weight: .heavy))
            .padding(.horizontal, w * 0.006)
            .padding(.vertical, w * 0.002)
            .overlay(RoundedRectangle(cornerRadius: w * 0.003).strokeBorder(.white.opacity(0.8), lineWidth: 0.8))
            .foregroundStyle(.white.opacity(0.85))
    }
}

// MARK: - Réglages d'un vinyle (dans « Personnaliser »)

struct VinylOptionsSection: View {
    let album: AlbumInfo
    @Environment(Library.self) private var library

    private var options: VinylOptions { library.vinylOptions(album.id) }

    private func update(_ change: (inout VinylOptions) -> Void) {
        var o = options
        change(&o)
        guard o != options else { return }
        library.setVinylOptions(o, for: album.id)
    }

    var body: some View {
        let o = options
        Section("Disque") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 10)], spacing: 12) {
                ForEach(VinylColor.allCases) { color in
                    let on = o.color == color
                    Button {
                        update { $0.color = color }
                    } label: {
                        VStack(spacing: 5) {
                            ZStack {
                                Circle().fill(LinearGradient(colors: color.swatch.count > 1 ? color.swatch : color.swatch + color.swatch,
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                Circle().strokeBorder(.white.opacity(0.15), lineWidth: 6).padding(5)
                                Circle().fill(Color(white: 0.85)).frame(width: 12, height: 12)
                                Circle().fill(Color.black).frame(width: 3, height: 3)
                            }
                            .frame(width: 46, height: 46)
                            .overlay(Circle().strokeBorder(on ? Color.white : .clear, lineWidth: 2).padding(-3))
                            Text(color.label).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                    .buttonStyle(PressStyle(circle: false))
                    .sensoryFeedback(.selection, trigger: on)
                }
            }
            .padding(.vertical, 6)
            Picker("Disques", selection: Binding(get: { o.discs }, set: { v in update { $0.discs = v } })) {
                ForEach(DiscCount.allCases) { Text($0.label).tag($0) }
            }
        }
        Section {
            Picker("Finition", selection: Binding(get: { o.finish }, set: { v in update { $0.finish = v } })) {
                ForEach(JacketFinish.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Pochette ouvrante (gatefold)", isOn: Binding(get: { o.gatefold }, set: { v in update { $0.gatefold = v } }))
            Picker("Sous-pochette", selection: Binding(get: { o.sleeve }, set: { v in update { $0.sleeve = v } })) {
                ForEach(SleeveKind.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Pochette")
        } footer: {
            Text("« Auto » met l’album sur deux disques au-delà de 46 minutes, comme les vrais pressages.")
        }
        Section {
            Toggle("Sticker sur le blister", isOn: Binding(get: { o.hype }, set: { v in update { $0.hype = v } }))
            if o.hype {
                HypeTextField(album: album, text: o.hypeText)
            }
        } header: {
            Text("Sticker « Inclut… »")
        } footer: {
            Text("Laisse vide : Platine écrit « Inclut le single » avec ton morceau le plus écouté.")
        }
    }
}

/// Texte du sticker, enregistré quand tu valides (le modèle 3D n'est pas refait à chaque lettre).
private struct HypeTextField: View {
    let album: AlbumInfo
    let text: String
    @Environment(Library.self) private var library
    @State private var draft = ""

    var body: some View {
        TextField("Texte du sticker", text: $draft)
            .submitLabel(.done)
            .onAppear { draft = text }
            .onSubmit { save() }
            .onDisappear { save() }
    }

    private func save() {
        var o = library.vinylOptions(album.id)
        let clean = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean != o.hypeText else { return }
        o.hypeText = String(clean.prefix(60))
        library.setVinylOptions(o, for: album.id)
    }
}

/// Le prix écrit sur l'étiquette du disquaire.
struct PriceSection: View {
    let album: AlbumInfo
    var discs = 1
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var draft = ""

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Étiquettes prix", isOn: $settings.priceStickers)
            if settings.priceStickers {
                HStack {
                    Text("Prix")
                    Spacer()
                    TextField(PriceTag.text(library.price(for: album.id, discs: discs)), text: $draft)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                        .onSubmit { save() }
                    Text("€").foregroundStyle(.secondary)
                }
                if library.hasCustomPrice(album.id) {
                    Button("Prix proposé par Platine") {
                        draft = ""
                        library.setPrice(nil, for: album.id)
                    }
                }
                Button("Appliquer ce prix") { save() }
                    .disabled(draft.isEmpty)
            }
        } header: {
            Text("Étiquette prix")
        } footer: {
            Text("Collée sur le boîtier ou la pochette, comme chez un disquaire.")
        }
        .onAppear {
            if library.hasCustomPrice(album.id) {
                draft = String(format: "%.2f", library.price(for: album.id, discs: discs)).replacingOccurrences(of: ".", with: ",")
            }
        }
    }

    private func save() {
        let clean = draft.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "€", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(clean), value > 0, value < 10_000 else { return }
        library.setPrice(value, for: album.id)
    }
}

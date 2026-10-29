import SwiftUI
import AVFoundation
import MediaPlayer

/// Écran « En lecture » plein écran.
struct NowPlayingView: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var editing: EditTarget?
    @State private var editingInfo: EditTarget?
    @State private var addTarget: AddToPlaylistTarget?
    @State private var showQueue = false
    @State private var showLyrics = false
    @State private var bounceNext = 0
    @State private var bouncePrev = 0
    /// Paroles en plein écran : les commandes se cachent après quelques secondes, comme dans Musique.
    @State private var controlsHidden = false
    @State private var hideTask: Task<Void, Never>?
    @State private var showEffects = false
    /// File d'attente affichée dans le lecteur (comme Musique), pas dans une feuille à part.
    @State private var queueOpen = false
    @Namespace private var artSpace
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let track = player.currentID.flatMap { library.track($0) }
        let landscape = verticalSizeClass == .compact
        // Comme Musique : une pochette animée remplit tout le haut de l'écran ; une image reste un carré.
        // En paysage, la pochette (animée ou non) reste un carré à gauche.
        let fullBleed = !landscape && (track.map { isAnimated($0) } ?? false)
        Group {
            if landscape {
                // Mode paysage : la pochette, les paroles ou la file à gauche, les commandes à droite.
                HStack(spacing: 34) {
                    VStack(spacing: 0) { mainArea(track, fullBleed: false) }
                        .frame(maxWidth: .infinity)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        controls(track, landscape: true)
                    }
                    .frame(maxWidth: 400)
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 14)
            } else {
                VStack(spacing: 0) {
                    mainArea(track, fullBleed: fullBleed)
                    controls(track, landscape: false)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 6)
            }
        }
        .foregroundStyle(.white)
        .background {
            ZStack(alignment: .top) {
                AmbientBackground(track: track, dim: fullBleed ? 0.55 : 0.3, forceDark: true)
                // Comme Musique : derrière les paroles, seulement les couleurs floues de la pochette.
                if fullBleed && !showLyrics, let t = track {
                    FullBleedArtwork(track: t)
                        .id(t.id)
                        .transition(.opacity)
                }
            }
            .ignoresSafeArea()
        }
        .animation(.smooth(duration: 0.45), value: player.currentID)
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: showLyrics)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: queueOpen)
        .animation(.spring(response: 0.5, dampingFraction: 0.9), value: controlsHidden)
        .onChange(of: showLyrics) { _, on in
            if on { pokeControls() } else { controlsHidden = false; hideTask?.cancel() }
        }
        .onChange(of: player.isPlaying) { _, _ in pokeControls() }
        .sheet(item: $editing) { target in
            ArtworkEditor(trackID: target.id)
        }
        .sheet(item: $editingInfo) { target in
            TrackInfoEditor(trackID: target.id)
        }
        .sheet(item: $addTarget) { target in
            AddToPlaylistSheet(target: target)
        }
        .sheet(isPresented: $showQueue) {
            QueueView()
        }
        .sheet(isPresented: $showEffects) {
            EffectsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .environment(\.colorScheme, .dark)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: player.effect)
        .onChange(of: player.currentID) { _, id in
            if id == nil { dismiss() }
        }
    }

    /// La grande zone : pochette, paroles ou file d'attente.
    @ViewBuilder private func mainArea(_ track: Track?, fullBleed: Bool) -> some View {
        if player.sleepActive {
            sleepBadge.padding(.top, 14)
        }
        if showLyrics, let t = track {
            lyricsHeader(t)
                .padding(.top, 20)
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .offset(y: -10)))
            LyricsPane(track: t, onInteract: pokeControls)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .simultaneousGesture(TapGesture().onEnded { pokeControls() })
        } else if queueOpen, let t = track {
            // Comme Musique : la pochette rétrécit en haut à gauche et la file apparaît dessous.
            lyricsHeader(t)
                .padding(.top, 20)
                .padding(.bottom, 10)
            InlineQueue()
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else if fullBleed {
            // L'image est derrière : on laisse juste l'espace pour la voir.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { if let t = track { editing = EditTarget(id: t.id) } }
        } else {
            Spacer(minLength: 24)
            artwork(track)
            Spacer(minLength: 24)
        }
    }

    /// Titre, barre, lecture, volume et boutons du bas.
    @ViewBuilder private func controls(_ track: Track?, landscape: Bool) -> some View {
        if !(showLyrics && controlsHidden) {
            VStack(spacing: 0) {
                if !showLyrics && !queueOpen {
                    header(track)
                        .padding(.bottom, landscape ? 14 : 22)
                        .transition(.opacity)
                }
                Scrubber()
                    .padding(.bottom, landscape ? 10 : 18)
                transport
                    .padding(.bottom, landscape ? 14 : 26)
                if !showLyrics {
                    volume
                        .padding(.bottom, landscape ? 14 : 26)
                        .transition(.opacity)
                }
                bottomBar
            }
            .padding(.top, showLyrics || queueOpen ? 14 : 0)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Réaffiche les commandes, puis les cache de nouveau après 3,5 s si les paroles sont affichées.
    private func pokeControls() {
        controlsHidden = false
        hideTask?.cancel()
        guard showLyrics else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, showLyrics, player.isPlaying, !showEffects else { return }
            controlsHidden = true
        }
    }

    /// En haut des paroles : petite pochette, titre et artiste (comme Musique).
    private func lyricsHeader(_ t: Track) -> some View {
        HStack(spacing: 12) {
            ArtworkView(track: t, animated: false, small: true, cornerRadius: 8)
                .frame(width: 50, height: 50)
                .matchedGeometryEffect(id: "artwork", in: artSpace)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            header(t)
        }
    }

    private func isAnimated(_ t: Track) -> Bool {
        settings.animatedArtwork && library.motion(t) != nil
    }

    // MARK: Pochette

    private func artwork(_ t: Track?) -> some View {
        // Changement de morceau : fondu doux avec un léger flou, comme dans Musique.
        ZStack {
            ArtworkView(track: t, cornerRadius: 12)
                .id(t?.id)
                .transition(.blurReplace)
        }
        .aspectRatio(1, contentMode: .fit)
        .matchedGeometryEffect(id: "artwork", in: artSpace)
            // Comme Musique : la pochette rétrécit en pause et reprend sa taille à la lecture.
            .scaleEffect(player.isPlaying ? 1 : 0.78)
            .shadow(color: .black.opacity(player.isPlaying ? 0.5 : 0.25),
                    radius: player.isPlaying ? 30 : 14, y: player.isPlaying ? 18 : 8)
            .animation(.spring(response: 0.5, dampingFraction: 0.72), value: player.isPlaying)
            .contentShape(Rectangle())
            .onTapGesture {
                if let t { editing = EditTarget(id: t.id) }
            }
            .accessibilityLabel("Pochette")
            .accessibilityHint("Touche pour changer la pochette")
            .accessibilityAddTraits(.isButton)
    }

    private var sleepBadge: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz.fill")
                if player.sleepAtTrackEnd {
                    Text("Arrêt à la fin du morceau")
                } else if let end = player.sleepEndDate {
                    Text("Arrêt dans " + formatTime(max(0, end.timeIntervalSince(context.date))))
                        .monospacedDigit()
                }
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassCapsule()
        }
    }

    // MARK: Titre

    private func header(_ t: Track?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(t?.title ?? "Aucun morceau")
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    if t?.explicit == true { ExplicitBadge(size: 18) }
                }
                Text(t?.displayArtist ?? "")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                if player.effect != .original {
                    // L'effet en cours, toujours visible : un toucher pour le changer.
                    Button { showEffects = true } label: {
                        Label(player.effect.title, systemImage: player.effect.symbol)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(.white.opacity(0.16)))
                    }
                    .buttonStyle(PressStyle(circle: false))
                    .padding(.top, 6)
                    .transition(.scale(scale: 0.8, anchor: .leading).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(t?.id)
            .transition(.opacity.combined(with: .offset(y: 6)))

            if let t {
                Button {
                    library.toggleFavorite(t.id)
                } label: {
                    Image(systemName: t.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.white.opacity(0.14)))
                }
                .buttonStyle(PressStyle(circle: false))
                .sensoryFeedback(trigger: t.isFavorite) { _, _ in settings.haptics ? .success : nil }
                .accessibilityLabel(t.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris")

                Menu {
                    Button("Ajouter à une playlist", systemImage: "text.badge.plus") {
                        addTarget = AddToPlaylistTarget(trackIDs: [t.id])
                    }
                    Divider()
                    Button(player.shuffle ? "Désactiver l’aléatoire" : "Lecture aléatoire", systemImage: "shuffle") {
                        player.setShuffle(!player.shuffle)
                    }
                    Button(repeatLabel, systemImage: player.repeatMode == .one ? "repeat.1" : "repeat") {
                        player.cycleRepeat()
                    }
                    Button("Effets : " + player.effect.title, systemImage: "dial.medium") {
                        showEffects = true
                    }
                    Divider()
                    Button("Changer la pochette", systemImage: "photo.on.rectangle") {
                        editing = EditTarget(id: t.id)
                    }
                    Button("Modifier les infos", systemImage: "pencil") {
                        editingInfo = EditTarget(id: t.id)
                    }
                    Menu {
                        ForEach([15, 30, 45, 60, 90], id: \.self) { m in
                            Button("\(m) minutes") { player.setSleepTimer(minutes: m) }
                        }
                        Button("À la fin du morceau") { player.setSleepAtTrackEnd() }
                        if player.sleepActive {
                            Button("Désactiver", role: .destructive) { player.setSleepTimer(minutes: nil) }
                        }
                    } label: {
                        Label("Minuterie de sommeil", systemImage: "moon.zzz")
                    }
                    Menu {
                        Picker("Vitesse", selection: Binding(get: { settings.playbackSpeed }, set: { player.setSpeed($0) })) {
                            ForEach(AppSettings.speeds, id: \.self) { Text(AppSettings.speedLabel($0)).tag($0) }
                        }
                    } label: {
                        Label("Vitesse : " + AppSettings.speedLabel(settings.playbackSpeed), systemImage: "speedometer")
                    }
                    Divider()
                    Button("Arrêter la lecture", systemImage: "stop.fill") {
                        player.quit()
                    }
                    Button("Retirer de la bibliothèque", systemImage: "trash", role: .destructive) {
                        library.remove([t.id])
                        player.removed([t.id])
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 19, weight: .bold))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.white.opacity(0.14)))
                }
                .accessibilityLabel("Plus d’options")
            }
        }
    }

    // MARK: Lecture

    private var transport: some View {
        HStack {
            Button {
                bouncePrev += 1
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 34))
                    .symbolEffect(.bounce, value: bouncePrev)
                    .frame(width: 66, height: 66)
            }
            .accessibilityLabel("Précédent")

            Spacer()

            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 50))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 86, height: 86)
            }
            .sensoryFeedback(trigger: player.isPlaying) { _, _ in settings.haptics ? .impact(weight: .medium) : nil }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Lecture")

            Spacer()

            Button {
                bounceNext += 1
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 34))
                    .symbolEffect(.bounce, value: bounceNext)
                    .frame(width: 66, height: 66)
            }
            .accessibilityLabel("Suivant")
        }
        .buttonStyle(PressStyle())
        .padding(.horizontal, 10)
    }

    private var volume: some View {
        HStack(spacing: 14) {
            Image(systemName: "speaker.fill").font(.footnote)
            VolumeBar()
            Image(systemName: "speaker.wave.3.fill").font(.footnote)
        }
        .foregroundStyle(.white.opacity(0.55))
    }

    private var repeatLabel: String {
        switch player.repeatMode {
        case .off: return "Répéter"
        case .one: return "Répéter : un morceau"
        default: return "Répéter : tout"
        }
    }

    /// Comme Musique : paroles, appareil de sortie (avec son nom) et file d'attente.
    private var bottomBar: some View {
        HStack(alignment: .top, spacing: 0) {
            toggle(symbol: "quote.bubble", on: showLyrics, label: "Paroles") {
                showLyrics.toggle()
                if showLyrics { queueOpen = false }
            }
            Spacer()
            VStack(spacing: 4) {
                RoutePicker()
                    .frame(width: 44, height: 36)
                    .accessibilityLabel("AirPlay et appareils audio")
                OutputName()
            }
            Spacer()
            ZStack(alignment: .topTrailing) {
                toggle(symbol: "list.bullet", on: queueOpen, label: "File d’attente") {
                    queueOpen.toggle()
                    if queueOpen { showLyrics = false }
                }
                // Petit badge quand l'aléatoire ou la répétition est activé.
                if player.shuffle || player.repeatMode != .off {
                    Image(systemName: player.shuffle ? "shuffle" : (player.repeatMode == .one ? "repeat.1" : "repeat"))
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color(white: 0.28)))
                        .offset(x: 6, y: -8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 6)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: player.shuffle)
    }

    private func toggle(symbol: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: on && symbol != "list.bullet" ? symbol + ".fill" : symbol)
                .font(.system(size: 21, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.55))
                .frame(width: 46, height: 36)
                .background(Capsule().fill(.white.opacity(on && symbol == "list.bullet" ? 0.16 : 0)))
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: on)
        }
        .buttonStyle(PressStyle(circle: false))
        .sensoryFeedback(trigger: on) { _, _ in settings.haptics ? .selection : nil }
        .accessibilityLabel(label)
        .accessibilityValue(on ? "Activé" : "Désactivé")
    }
}


// MARK: - Grande pochette animée (comme Musique)

/// La pochette animée prend toute la largeur en haut, passe sous la barre d'état
/// et se fond longuement dans le fond, derrière le titre.
struct FullBleedArtwork: View {
    let track: Track

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ArtworkView(track: track, animated: true, cornerRadius: 0, bordered: false)
                .frame(width: w, height: min(geo.size.height * 0.68, w * 1.4))
                .clipped()
                .mask(
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.6),
                        .init(color: .black.opacity(0.8), location: 0.72),
                        .init(color: .black.opacity(0.45), location: 0.84),
                        .init(color: .black.opacity(0.15), location: 0.93),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Barre de volume (style Musique)

/// Barre épaisse sans point, comme dans Musique. Elle pilote le volume de l'iPhone.
/// Elle vit sous le doigt : elle gonfle avec un léger rebond, s'étire comme un élastique
/// quand on tire au-delà des bords, et revient en souplesse.
struct VolumeBar: View {
    @State private var model = VolumeModel()
    @State private var dragStart: Float?
    /// Étirement élastique au-delà des bords (en points, négatif = côté gauche).
    @State private var stretch: CGFloat = 0

    var body: some View {
        let active = dragStart != nil
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(active ? 0.24 : 0.2))
                Capsule().fill(.white.opacity(active ? 1 : 0.62))
                    .frame(width: width * CGFloat(model.volume))
                    // Suit le doigt de près pendant le geste ; glisse en douceur sinon (boutons de l'iPhone).
                    .animation(active ? .interactiveSpring(response: 0.18, dampingFraction: 0.86)
                                      : .spring(response: 0.45, dampingFraction: 0.82), value: model.volume)
            }
            .frame(height: active ? 13 : 7)
            // L'élastique : la barre s'allonge du côté où l'on tire, et s'amincit un peu.
            .scaleEffect(x: 1 + abs(stretch) / width, y: 1 - min(abs(stretch), 24) / 120,
                         anchor: stretch >= 0 ? .leading : .trailing)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragStart == nil { dragStart = model.volume }
                        let raw = (dragStart ?? 0) + Float((g.location.x - g.startLocation.x) / width)
                        let clamped = min(1, max(0, raw))
                        model.set(clamped)
                        // Au-delà des bords : résistance de plus en plus forte.
                        let over = CGFloat(raw - clamped) * width
                        stretch = over == 0 ? 0 : (over > 0 ? 1 : -1) * 22 * (1 - 1 / (1 + abs(over) / 60))
                    }
                    .onEnded { _ in
                        dragStart = nil
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { stretch = 0 }
                    }
            )
        }
        .frame(height: 30)
        .animation(.spring(response: 0.42, dampingFraction: 0.62), value: active)
        .sensoryFeedback(.impact(weight: .light), trigger: model.volume == 0 || model.volume == 1)
        // Le vrai réglage système, caché (il évite aussi la bulle de volume d'iOS).
        .background { HiddenVolumeView(model: model).frame(width: 1, height: 1).opacity(0.01) }
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(model.volume * 100)) %")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.set(min(1, model.volume + 0.0625))
            case .decrement: model.set(max(0, model.volume - 0.0625))
            @unknown default: break
            }
        }
    }
}

@MainActor @Observable
final class VolumeModel {
    var volume: Float = AVAudioSession.sharedInstance().outputVolume
    @ObservationIgnored weak var slider: UISlider?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            let v = change.newValue ?? 0
            Task { @MainActor in self?.volume = v }
        }
    }

    func set(_ v: Float) {
        volume = v
        slider?.setValue(v, animated: false)
        slider?.sendActions(for: .valueChanged)
    }
}

struct HiddenVolumeView: UIViewRepresentable {
    let model: VolumeModel

    func makeUIView(context: Context) -> MPVolumeView {
        MPVolumeView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        if model.slider == nil { model.slider = Self.findSlider(in: uiView) }
    }

    static func findSlider(in view: UIView) -> UISlider? {
        if let s = view as? UISlider { return s }
        for sub in view.subviews {
            if let s = findSlider(in: sub) { return s }
        }
        return nil
    }
}

/// Nom de l'appareil qui joue le son (« AirPods de… », « iPhone »), comme sous l'icône AirPlay de Musique.
struct OutputName: View {
    @State private var name = OutputName.current()

    var body: some View {
        Text(name)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .fixedSize()
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in
                name = OutputName.current()
            }
    }

    static func current() -> String {
        let out = AVAudioSession.sharedInstance().currentRoute.outputs.first
        if out?.portType == .builtInSpeaker || out?.portType == .builtInReceiver { return "iPhone" }
        return out?.portName ?? "iPhone"
    }
}


// MARK: - Effets d'écoute

/// Choix de l'effet : slowed, sped up, réverbe… avec l'intensité de l'écho.
struct EffectsSheet: View {
    @Environment(Player.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    card(.original)
                    section("Vitesse", SoundEffect.speedGroup)
                    section("Réverbe", SoundEffect.reverbGroup)
                    if player.effect.reverb != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Intensité de l’écho").font(.headline)
                            HStack(spacing: 12) {
                                Image(systemName: "drop").foregroundStyle(.secondary)
                                Slider(value: Binding(get: { player.effectIntensity },
                                                      set: { player.setEffectIntensity($0) }), in: 0...1)
                                    .tint(.white)
                                Image(systemName: "drop.fill").foregroundStyle(.secondary)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    Text("Ton fichier n’est jamais modifié : l’effet est ajouté seulement pendant l’écoute, et reste choisi pour les morceaux suivants jusqu’à ce que tu reviennes à « Original ».")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: player.effect)
            }
            .navigationTitle("Effets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    private func section(_ title: String, _ effects: [SoundEffect]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(effects) { card($0) }
            }
        }
    }

    private func card(_ effect: SoundEffect) -> some View {
        let selected = player.effect == effect
        return Button {
            player.setEffect(effect)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: effect.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(selected ? Color.black.opacity(0.12) : Color.white.opacity(0.1)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(effect.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(effect.subtitle).font(.caption).lineLimit(2)
                        .foregroundStyle(selected ? Color.black.opacity(0.6) : Color.white.opacity(0.55))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.black : Color.white)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(selected ? Color.white : Color.white.opacity(0.08)))
        }
        .buttonStyle(PressStyle(circle: false))
        .sensoryFeedback(.selection, trigger: selected)
    }
}


// MARK: - File d'attente dans le lecteur (comme Musique)

/// Aléatoire, répétition, puis « À suivre » et la suite, directement dans le lecteur.
struct InlineQueue: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                pill("shuffle", on: player.shuffle) { player.setShuffle(!player.shuffle) }
                pill(player.repeatMode == .one ? "repeat.1" : "repeat", on: player.repeatMode != .off) { player.cycleRepeat() }
                if !player.upNext.isEmpty {
                    pill("xmark", on: false) { player.clearUpNext() }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !player.upNext.isEmpty {
                        sectionTitle("À suivre")
                        ForEach(Array(player.upNext.enumerated()), id: \.offset) { i, id in
                            if let t = library.track(id) {
                                row(t) { player.playUpNext(at: i) }
                            }
                        }
                    }
                    let upcoming = Array(player.upcomingInQueue.prefix(150))
                    if !upcoming.isEmpty {
                        sectionTitle(player.shuffle ? "Ensuite · aléatoire" : "Ensuite")
                        ForEach(upcoming, id: \.self) { qi in
                            if let t = library.track(player.queue[qi]) {
                                row(t) { player.jump(toQueueIndex: qi) }
                            }
                        }
                    }
                    if player.upNext.isEmpty && upcoming.isEmpty {
                        Text("La file d’attente ne comporte aucune musique.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .mask(LyricsFade())
        }
        .frame(maxHeight: .infinity)
    }

    private func pill(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(on ? Color.black : Color.white)
                .frame(width: 66, height: 34)
                .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.14)))
        }
        .buttonStyle(PressStyle(circle: false))
        .sensoryFeedback(.selection, trigger: on)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private func row(_ t: Track, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ArtworkView(track: t, animated: false, small: true, cornerRadius: 6)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(t.title).font(.body.weight(.medium)).lineLimit(1)
                        if t.explicit { ExplicitBadge(size: 13) }
                    }
                    Text(t.displayArtist).font(.subheadline).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(circle: false))
    }
}

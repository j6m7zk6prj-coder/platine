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
    @State private var showSing = false

    var body: some View {
        let track = player.currentID.flatMap { library.track($0) }
        // Comme Musique : une pochette animée remplit tout le haut de l'écran ; une image reste un carré.
        let fullBleed = track.map { isAnimated($0) } ?? false
        VStack(spacing: 0) {
            if player.sleepActive {
                sleepBadge.padding(.top, 14)
            }
            if showLyrics, let t = track {
                lyricsHeader(t)
                    .padding(.top, 20)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .offset(y: -10)))
                ZStack(alignment: .bottomTrailing) {
                    LyricsPane(track: t, onInteract: pokeControls)
                    singControl
                        .padding(.bottom, 10)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .simultaneousGesture(TapGesture().onEnded { pokeControls() })
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
            if !(showLyrics && controlsHidden) {
            VStack(spacing: 0) {
                if !showLyrics {
                    header(track)
                        .padding(.bottom, 22)
                        .transition(.opacity)
                }
                Scrubber()
                    .padding(.bottom, 18)
                transport
                    .padding(.bottom, 26)
                if !showLyrics {
                    volume
                        .padding(.bottom, 26)
                        .transition(.opacity)
                }
                bottomBar
            }
            .padding(.top, showLyrics ? 14 : 0)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 6)
        .foregroundStyle(.white)
        .background {
            ZStack(alignment: .top) {
                AmbientBackground(track: track, dim: fullBleed ? 0.55 : 0.3, forceDark: true)
                if fullBleed, let t = track {
                    FullBleedArtwork(track: t)
                        .opacity(showLyrics ? 0.3 : 1)
                        .id(t.id)
                        .transition(.opacity)
                }
            }
            .ignoresSafeArea()
        }
        .animation(.smooth(duration: 0.45), value: player.currentID)
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: showLyrics)
        .animation(.spring(response: 0.5, dampingFraction: 0.9), value: controlsHidden)
        .onChange(of: showLyrics) { _, on in
            showSing = false
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
        .onChange(of: player.currentID) { _, id in
            if id == nil { dismiss() }
        }
    }

    /// Réaffiche les commandes, puis les cache de nouveau après 3,5 s si les paroles sont affichées.
    private func pokeControls() {
        controlsHidden = false
        hideTask?.cancel()
        guard showLyrics else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, showLyrics, player.isPlaying, !showSing else { return }
            controlsHidden = true
        }
    }

    /// En haut des paroles : petite pochette, titre et artiste (comme Musique).
    private func lyricsHeader(_ t: Track) -> some View {
        HStack(spacing: 12) {
            ArtworkView(track: t, animated: false, small: true, cornerRadius: 8)
                .frame(width: 50, height: 50)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            header(t)
        }
    }

    /// Mode instrumental : un micro, et un curseur vertical pour baisser la voix (comme « Apple Music Sing »).
    private var singControl: some View {
        VStack(spacing: 10) {
            if showSing {
                VocalSlider(value: Binding(get: { player.vocalReduction }, set: { player.vocalReduction = $0 }))
                    .frame(width: 44, height: 160)
                    .transition(.scale(scale: 0.4, anchor: .bottom).combined(with: .opacity))
            }
            Button {
                showSing.toggle()
                pokeControls()
            } label: {
                Image(systemName: player.vocalReduction > 0.01 ? "music.mic.circle.fill" : "music.mic.circle")
                    .font(.system(size: 30, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(player.vocalReduction > 0.01 || showSing ? 1 : 0.6))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Instrumental")
            .accessibilityValue("Voix réduite de \(Int(player.vocalReduction * 100)) %")
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: showSing)
    }

    private func isAnimated(_ t: Track) -> Bool {
        guard settings.animatedArtwork, library.artworkURL(t) != nil else { return false }
        let kind = library.artworkKind(t)
        return kind == .video || kind == .gif
    }

    // MARK: Pochette

    private func artwork(_ t: Track?) -> some View {
        ArtworkView(track: t, cornerRadius: 12)
            .aspectRatio(1, contentMode: .fit)
            .id(t?.id)
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.04)),
                                    removal: .opacity.combined(with: .scale(scale: 0.97))))
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
                    Button(player.vocalReduction > 0.5 ? "Remettre la voix" : "Instrumental (sans la voix)",
                           systemImage: "music.mic") {
                        player.vocalReduction = player.vocalReduction > 0.5 ? 0 : 1
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
                toggle(symbol: "list.bullet", on: false, label: "File d’attente") {
                    showQueue = true
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
            Image(systemName: on ? symbol + ".fill" : symbol)
                .font(.system(size: 21, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.55))
                .frame(width: 46, height: 36)
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
struct VolumeBar: View {
    @State private var model = VolumeModel()
    @State private var dragStart: Float?

    var body: some View {
        let active = dragStart != nil
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white.opacity(active ? 1 : 0.6))
                    .frame(width: width * CGFloat(model.volume))
            }
            .frame(height: active ? 12 : 7)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragStart == nil { dragStart = model.volume }
                        let moved = Float((g.location.x - g.startLocation.x) / width)
                        model.set(min(1, max(0, (dragStart ?? 0) + moved)))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: active)
        }
        .frame(height: 28)
        .scaleEffect(x: active ? 1.03 : 1, y: 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: active)
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


// MARK: - Curseur de la voix (mode instrumental)

/// Curseur vertical : en haut = voix normale, en bas = voix presque retirée.
struct VocalSlider: View {
    @Binding var value: Double
    @State private var start: Double?

    var body: some View {
        GeometryReader { geo in
            let h = max(geo.size.height, 1)
            // Partie claire = la voix qui reste.
            let voice = 1 - value
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.16))
                Capsule().fill(.white.opacity(0.9))
                    .frame(height: max(geo.size.width, h * voice))
                    .opacity(voice > 0.02 ? 1 : 0.25)
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(voice > 0.2 ? Color.black.opacity(0.6) : Color.white.opacity(0.7))
                    .padding(.bottom, 14)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if start == nil { start = value }
                        let moved = Double(g.translation.height / h)
                        value = min(1, max(0, (start ?? 0) + moved))
                    }
                    .onEnded { _ in start = nil }
            )
        }
        .background(.ultraThinMaterial, in: Capsule())
        .sensoryFeedback(.selection, trigger: value == 0 || value == 1)
        .accessibilityElement()
        .accessibilityLabel("Volume de la voix")
        .accessibilityValue("\(Int((1 - value) * 100)) %")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = max(0, value - 0.1)
            case .decrement: value = min(1, value + 0.1)
            @unknown default: break
            }
        }
    }
}

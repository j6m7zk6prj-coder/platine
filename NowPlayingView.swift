import SwiftUI

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

    var body: some View {
        let track = player.currentID.flatMap { library.track($0) }
        VStack(spacing: 0) {
            if player.sleepActive {
                sleepBadge.padding(.top, 14)
            }
            Spacer(minLength: 18)
            if showLyrics, let t = track {
                LyricsPane(track: t)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                artwork(track)
            }
            Spacer(minLength: 18)
            VStack(spacing: 20) {
                header(track)
                Scrubber()
                transport
                if !showLyrics {
                    volume.transition(.opacity)
                }
                bottomBar
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 10)
        .foregroundStyle(.white)
        .background { AmbientBackground(track: track, dim: 0.26, forceDark: true) }
        .animation(.smooth(duration: 0.45), value: player.currentID)
        .animation(.smooth(duration: 0.4), value: showLyrics)
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

    // MARK: Pochette

    private func artwork(_ t: Track?) -> some View {
        ArtworkView(track: t, cornerRadius: 14)
            .aspectRatio(1, contentMode: .fit)
            .id(t?.id)
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.04)),
                                    removal: .opacity.combined(with: .scale(scale: 0.97))))
            .scaleEffect(player.isPlaying ? 1 : 0.8)
            .shadow(color: .black.opacity(player.isPlaying ? 0.45 : 0.25),
                    radius: player.isPlaying ? 32 : 16, y: player.isPlaying ? 22 : 10)
            .animation(.spring(response: 0.6, dampingFraction: 0.7), value: player.isPlaying)
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
                Text(t?.title ?? "Aucun morceau")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(t.map { [$0.displayArtist, $0.album].filter { !$0.isEmpty }.joined(separator: " — ") } ?? "")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(t?.id)
            .transition(.opacity.combined(with: .offset(y: 6)))

            if let t {
                Button {
                    library.toggleFavorite(t.id)
                } label: {
                    Image(systemName: t.isFavorite ? "heart.fill" : "heart")
                        .font(.body.weight(.bold))
                        .foregroundStyle(t.isFavorite ? AnyShapeStyle(.tint) : AnyShapeStyle(.white))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 36, height: 36)
                        .glassCircle()
                }
                .buttonStyle(PressStyle(circle: false))
                .sensoryFeedback(trigger: t.isFavorite) { _, _ in settings.haptics ? .success : nil }
                .accessibilityLabel(t.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris")

                Menu {
                    Button("Ajouter à une playlist", systemImage: "text.badge.plus") {
                        addTarget = AddToPlaylistTarget(trackIDs: [t.id])
                    }
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
                        .font(.body.weight(.bold))
                        .frame(width: 36, height: 36)
                        .glassCircle()
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
                    .font(.system(size: 30))
                    .symbolEffect(.bounce, value: bouncePrev)
                    .frame(width: 66, height: 66)
            }
            .accessibilityLabel("Précédent")

            Spacer()

            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 46))
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
                    .font(.system(size: 30))
                    .symbolEffect(.bounce, value: bounceNext)
                    .frame(width: 66, height: 66)
            }
            .accessibilityLabel("Suivant")
        }
        .buttonStyle(PressStyle())
        .padding(.horizontal, 10)
    }

    private var volume: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill").font(.caption)
            SystemVolumeSlider().frame(height: 30)
            Image(systemName: "speaker.wave.3.fill").font(.caption)
        }
        .foregroundStyle(.white.opacity(0.55))
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            toggle(symbol: "quote.bubble", on: showLyrics, label: "Paroles") {
                showLyrics.toggle()
            }
            Spacer()
            toggle(symbol: "shuffle", on: player.shuffle, label: "Lecture aléatoire") {
                player.setShuffle(!player.shuffle)
            }
            Spacer()
            RoutePicker()
                .frame(width: 44, height: 36)
                .accessibilityLabel("AirPlay et appareils audio")
            Spacer()
            toggle(symbol: player.repeatMode == .one ? "repeat.1" : "repeat",
                   on: player.repeatMode != .off,
                   label: "Répéter") {
                player.cycleRepeat()
            }
            Spacer()
            toggle(symbol: "list.bullet", on: showQueue, label: "File d’attente") {
                showQueue = true
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassCapsule()
    }

    private func toggle(symbol: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(on ? Color.black : Color.white.opacity(0.75))
                .frame(width: 46, height: 36)
                .background(Capsule().fill(.white.opacity(on ? 0.95 : 0)))
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: on)
        }
        .buttonStyle(PressStyle(circle: false))
        .sensoryFeedback(trigger: on) { _, _ in settings.haptics ? .selection : nil }
        .accessibilityLabel(label)
        .accessibilityValue(on ? "Activé" : "Désactivé")
    }
}

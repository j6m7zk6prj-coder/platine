import SwiftUI

// MARK: - En lecture (comme Musique sur iOS 16)

struct NowPlayingView: View {
    enum Mode { case artwork, lyrics, queue }

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .artwork
    @State private var dragY: CGFloat = 0

    var body: some View {
        let t = player.currentID.flatMap { library.track($0) }
        ZStack {
            background(t)
            VStack(spacing: 0) {
                // La petite barre du haut : on glisse vers le bas pour refermer.
                Capsule()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: 38, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .gesture(dismissDrag)

                if mode == .artwork {
                    Spacer(minLength: 8)
                    bigArtwork(t).gesture(dismissDrag)
                    Spacer(minLength: 8)
                    titleRow(t).padding(.bottom, Device.isSmallScreen ? 14 : 22)
                } else {
                    smallHeader(t)
                        .padding(.top, 6)
                        .padding(.bottom, 10)
                        .gesture(dismissDrag)
                    Group {
                        if mode == .lyrics, let t {
                            LyricsPanel(track: t)
                        } else {
                            QueuePanel()
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
                }

                ScrubberBar().padding(.bottom, Device.isSmallScreen ? 6 : 12)
                transport.padding(.bottom, Device.isSmallScreen ? 8 : 16)
                volume.padding(.bottom, Device.isSmallScreen ? 10 : 18)
                bottomBar.padding(.bottom, 8)
            }
            .padding(.horizontal, 26)
        }
        .foregroundColor(.white)
        .environment(\.colorScheme, .dark)
        .offset(y: dragY)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: mode)
        .onChange(of: player.currentID) { id in if id == nil { dismiss() } }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { g in dragY = max(0, g.translation.height) }
            .onEnded { g in
                if g.translation.height > 140 || g.predictedEndTranslation.height > 400 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dragY = 0 }
                }
            }
    }

    /// Fond : les couleurs de la pochette, en dégradé (pas de flou en direct : plus léger pour l'iPhone 8).
    private func background(_ t: Track?) -> some View {
        let p = t.map { library.palette(for: $0) } ?? [Color(.systemGray), Color(.darkGray)]
        let top = p.first ?? Color(.systemGray)
        let bottom = p.count > 1 ? p[1] : top
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
            .overlay(Color.black.opacity(0.3))
            .animation(.easeInOut(duration: 0.5), value: t?.id)
            .ignoresSafeArea()
    }

    private func bigArtwork(_ t: Track?) -> some View {
        // Comme Musique : la pochette rétrécit en pause.
        Artwork(track: t, cornerRadius: 10, pixels: 800)
            .frame(maxWidth: .infinity)
            .scaleEffect(player.isPlaying ? 1 : 0.8)
            .shadow(color: .black.opacity(player.isPlaying ? 0.35 : 0.2), radius: player.isPlaying ? 24 : 10, y: player.isPlaying ? 14 : 6)
            .animation(.spring(response: 0.5, dampingFraction: 0.72), value: player.isPlaying)
    }

    private func titleRow(_ t: Track?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(t?.title ?? "À l’arrêt").font(.title3.bold()).lineLimit(1)
                    if t?.explicit == true { ExplicitBadge(size: 15) }
                }
                Text(t?.displayArtist ?? "").font(.title3).foregroundColor(.white.opacity(0.6)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let t { OptionsMenu(track: t) }
        }
    }

    private func smallHeader(_ t: Track?) -> some View {
        HStack(spacing: 14) {
            Artwork(track: t, cornerRadius: 6, pixels: 200)
                .frame(width: 62, height: 62)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(t?.title ?? "À l’arrêt").font(.headline).lineLimit(1)
                Text(t?.displayArtist ?? "").font(.subheadline).foregroundColor(.white.opacity(0.6)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let t { OptionsMenu(track: t) }
        }
    }

    private var transport: some View {
        HStack {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 32)).frame(width: 70, height: 64)
            }
            Spacer()
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 44)).frame(width: 80, height: 70)
            }
            .haptic(.impact(weight: .medium), trigger: player.isPlaying)
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 32)).frame(width: 70, height: 64)
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 6)
    }

    private var volume: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill").font(.footnote)
            SystemVolumeSlider().frame(height: 30)
            Image(systemName: "speaker.wave.3.fill").font(.footnote)
        }
        .foregroundColor(.white.opacity(0.6))
    }

    private var bottomBar: some View {
        HStack {
            toggle("quote.bubble", on: mode == .lyrics) { mode = mode == .lyrics ? .artwork : .lyrics }
            Spacer()
            RoutePicker().frame(width: 44, height: 44)
            Spacer()
            toggle("list.bullet", on: mode == .queue) { mode = mode == .queue ? .artwork : .queue }
        }
        .padding(.horizontal, 20)
    }

    /// Bouton du bas : blanc sur fond clair quand il est activé (comme Musique).
    private func toggle(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(on ? Color.black.opacity(0.7) : .white.opacity(0.7))
                .frame(width: 40, height: 36)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Color.white : Color.clear))
        }
        .haptic(.selection, trigger: on)
    }
}

/// Le menu « … » du lecteur.
private struct OptionsMenu: View {
    let track: Track
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: UIState

    var body: some View {
        Menu {
            IconButton(track.isFavorite ? "Ne plus aimer" : "Aimer", systemImage: track.isFavorite ? "heart.slash" : "heart") {
                library.toggleFavorite(track.id)
            }
            IconButton("Ajouter à une playlist…", systemImage: "text.badge.plus") {
                ui.addToPlaylist = AddToPlaylistTarget(trackIDs: [track.id])
            }
            IconButton("Modifier les infos", systemImage: "pencil") { ui.editingInfo = EditTarget(id: track.id) }
            Divider()
            Menu {
                Picker("Effet", selection: Binding(get: { player.effect }, set: { player.setEffect($0) })) {
                    ForEach(SoundEffect.allCases) { Text($0.title).tag($0) }
                }
            } label: { Label("Effet : " + player.effect.title, systemImage: "dial.min") }
            Menu {
                Picker("Vitesse", selection: Binding(get: { settings.playbackSpeed }, set: { player.setSpeed($0) })) {
                    ForEach(AppSettings.speeds, id: \.self) { Text(AppSettings.speedLabel($0)).tag($0) }
                }
            } label: { Label("Vitesse : " + AppSettings.speedLabel(settings.playbackSpeed), systemImage: "speedometer") }
            Menu {
                ForEach([15, 30, 45, 60], id: \.self) { m in
                    Button("\(m) minutes") { player.setSleepTimer(minutes: m) }
                }
                Button("À la fin du morceau") { player.setSleepAtTrackEnd() }
                if player.sleepActive {
                    Button("Désactiver", role: .destructive) { player.setSleepTimer(minutes: nil) }
                }
            } label: { Label(player.sleepActive ? "Minuterie (active)" : "Minuterie", systemImage: "moon.zzz") }
            Divider()
            IconButton("Arrêter la lecture", systemImage: "stop.fill") { player.quit() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.18)))
        }
    }
}

// MARK: - Barre de lecture

/// Fine barre qui s'épaissit sous le doigt, avec le temps écoulé et le temps restant.
struct ScrubberBar: View {
    @EnvironmentObject private var player: Player
    /// Seule cette barre suit l'avancée du morceau (dix fois par seconde).
    @ObservedObject private var clock = PlaybackClock.shared
    @State private var dragValue: Double?

    var body: some View {
        let total = max(player.duration, 0.01)
        let value = min(total, dragValue ?? clock.time)
        let active = dragValue != nil
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = max(geo.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.25))
                    Capsule().fill(Color.white.opacity(active ? 1 : 0.7)).frame(width: w * value / total)
                }
                .frame(height: active ? 10 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            player.isScrubbing = true
                            dragValue = min(total, max(0, Double(g.location.x / w) * total))
                        }
                        .onEnded { _ in
                            if let v = dragValue { player.seek(to: v) }
                            dragValue = nil
                            player.isScrubbing = false
                        }
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: active)
            }
            .frame(height: 24)
            HStack {
                Text(formatTime(value))
                Spacer()
                Text("-" + formatTime(total - value))
            }
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundColor(.white.opacity(0.55))
        }
    }
}

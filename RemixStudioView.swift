import SwiftUI
import AVFoundation

/// Aperçu en direct d'un remix : on entend chaque réglage tout de suite.
@MainActor @Observable
final class RemixPreview {
    var settings = RemixSettings() {
        didSet { settingsChanged(from: oldValue) }
    }
    private(set) var isPlaying = false
    /// Avancement dans le remix, en secondes (tel qu'on l'entend).
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var peaks: [Float] = []
    private(set) var ready = false

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var nodes: RemixGraph.Nodes?
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var restartTask: Task<Void, Never>?

    func load(_ url: URL) {
        guard file == nil, let f = try? AVAudioFile(forReading: url) else { return }
        file = f
        duration = Double(f.length) / f.processingFormat.sampleRate
        settings.end = duration
        nodes = RemixGraph.build(engine, file: f)
        if let nodes { RemixGraph.apply(settings, to: nodes) }
        engine.prepare()
        ready = true
        Task.detached(priority: .userInitiated) {
            let p = Self.waveform(url, bins: 160)
            await MainActor.run { self.peaks = p }
        }
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let nodes, let file else { return }
        do {
            if !engine.isRunning { try engine.start() }
        } catch { return }
        if position <= 0.01 || position >= settings.outputLength - 0.05 {
            restart(nodes, file)
        } else {
            nodes.player.play()
            nodes.drums.play()
        }
        isPlaying = true
        startTicker()
    }

    func pause() {
        nodes?.player.pause()
        nodes?.drums.pause()
        isPlaying = false
        ticker?.cancel()
    }

    func stop() {
        nodes?.player.stop()
        nodes?.drums.stop()
        engine.stop()
        isPlaying = false
        position = 0
        ticker?.cancel()
    }

    func rewind() {
        guard let nodes, let file else { return }
        position = 0
        if isPlaying { restart(nodes, file) } else {
            nodes.player.stop()
            nodes.drums.stop()
        }
    }

    private func restart(_ nodes: RemixGraph.Nodes, _ file: AVAudioFile) {
        nodes.player.stop()
        nodes.drums.stop()
        position = 0
        RemixGraph.schedule(settings, file: file, on: nodes)
        engine.mainMixerNode.outputVolume = settings.gain(at: 0)
        nodes.player.play()
        nodes.drums.play()
    }

    private func settingsChanged(from old: RemixSettings) {
        guard let nodes else { return }
        RemixGraph.apply(settings, to: nodes)
        // Passage, boucles ou batterie changés : on repart du début (après un court instant, pour ne pas
        // relancer à chaque petit mouvement du doigt).
        let structural = old.start != settings.start || old.end != settings.end || old.loops != settings.loops
            || old.beat != settings.beat || old.bpm != settings.bpm
        guard structural, isPlaying, let file else { return }
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled, self.isPlaying, let nodes = self.nodes else { return }
            self.restart(nodes, file)
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, let nodes = self.nodes else { return }
                if let nodeTime = nodes.player.lastRenderTime,
                   let playerTime = nodes.player.playerTime(forNodeTime: nodeTime) {
                    let source = Double(playerTime.sampleTime) / playerTime.sampleRate
                    self.position = max(0, source / self.settings.speed)
                }
                self.engine.mainMixerNode.outputVolume = self.settings.gain(at: self.position)
                if self.position >= self.settings.outputLength {
                    self.pause()
                    self.position = 0
                    nodes.player.stop()
                    nodes.drums.stop()
                }
            }
        }
    }

    /// Forme d'onde du son (valeurs de 0 à 1), pour choisir le passage.
    nonisolated static func waveform(_ url: URL, bins: Int) -> [Float] {
        guard let f = try? AVAudioFile(forReading: url) else { return [] }
        let total = f.length
        guard total > 0 else { return [] }
        let chunk = AVAudioFrameCount(max(1, total / Int64(bins)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: chunk) else { return [] }
        var result: [Float] = []
        for _ in 0..<bins {
            do { try f.read(into: buffer, frameCount: chunk) } catch { break }
            guard let data = buffer.floatChannelData?[0] else { break }
            var peak: Float = 0
            let n = Int(buffer.frameLength)
            var i = 0
            while i < n { peak = max(peak, abs(data[i])); i += 8 }
            result.append(peak)
            if buffer.frameLength < chunk { break }
        }
        let top = max(result.max() ?? 1, 0.01)
        return result.map { $0 / top }
    }
}

/// Studio remix : couper, boucler, ralentir ou accélérer, ajouter des effets et un beat, puis créer le remix.
struct RemixStudioView: View {
    let trackID: UUID
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var preview = RemixPreview()
    @State private var name = ""
    @State private var exporting = false
    @State private var progress = 0.0
    @State private var failed = false
    @State private var taps: [Date] = []

    var body: some View {
        @Bindable var preview = preview
        let track = library.track(trackID)
        ZStack {
            AmbientBackground(track: track, dim: 0.5, forceDark: true).ignoresSafeArea()
            if let track {
                VStack(spacing: 0) {
                    topBar
                    ScrollView {
                        VStack(spacing: 18) {
                            header(track)
                            waveform
                            transport
                            speedCard($preview.settings)
                            effectsCard($preview.settings)
                            loopCard($preview.settings)
                            beatCard($preview.settings)
                            exportCard(track)
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 40)
                    }
                    .scrollIndicators(.hidden)
                }
            } else {
                ContentUnavailableView("Morceau introuvable", systemImage: "music.note")
            }
            if exporting {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView(value: progress).tint(.white).frame(width: 220)
                    Text("Création du remix… \(Int(progress * 100)) %").font(.headline).monospacedDigit()
                }
                .padding(28)
                .glass(24)
            }
        }
        .foregroundStyle(.white)
        .onAppear {
            player.pause()
            if let track {
                name = track.title + " (Remix)"
                preview.load(library.audioURL(track))
            }
        }
        .onDisappear { preview.stop() }
        .alert("Le remix n’a pas pu être créé", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Essaie avec un passage plus court ou un autre son.")
        }
    }

    // MARK: Haut

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.bold)).frame(width: 40, height: 40).glassCircle()
            }
            .accessibilityLabel("Fermer")
            Spacer()
            Text("Studio remix").font(.headline)
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private func header(_ t: Track) -> some View {
        HStack(spacing: 14) {
            ArtworkView(track: t, animated: false, small: true, cornerRadius: 10)
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 3) {
                Text(t.title).font(.title3.bold()).lineLimit(1)
                Text(t.displayArtist).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                Text("Durée du remix : " + PhoneScreenContent.format(preview.settings.outputLength))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Forme d'onde et passage

    private var waveform: some View {
        let s = preview.settings
        let dur = max(preview.duration, 0.01)
        return VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                let x0 = w * s.start / dur
                let x1 = w * s.end / dur
                let loopPos = s.start + (preview.position * s.speed).truncatingRemainder(dividingBy: s.segmentLength)
                ZStack(alignment: .leading) {
                    HStack(alignment: .center, spacing: 1) {
                        ForEach(Array(preview.peaks.enumerated()), id: \.offset) { _, p in
                            Capsule().fill(.white.opacity(0.55)).frame(height: max(2, CGFloat(p) * geo.size.height))
                        }
                    }
                    .frame(width: w, height: geo.size.height)
                    // Ce qui est hors du passage est assombri.
                    Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, x0))
                    Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, w - x1)).offset(x: x1)
                    RoundedRectangle(cornerRadius: 6).strokeBorder(.white, lineWidth: 2)
                        .frame(width: max(8, x1 - x0)).offset(x: x0)
                    if preview.isPlaying {
                        Rectangle().fill(Color.accentColor).frame(width: 2).offset(x: w * loopPos / dur)
                    }
                    handle(x: x0, height: geo.size.height) { x in
                        preview.settings.start = min(max(0, Double(x / w) * dur), preview.settings.end - 1)
                    }
                    handle(x: x1, height: geo.size.height) { x in
                        preview.settings.end = max(min(dur, Double(x / w) * dur), preview.settings.start + 1)
                    }
                }
                .coordinateSpace(name: "wave")
            }
            .frame(height: 90)
            HStack {
                Text(PhoneScreenContent.format(s.start))
                Spacer()
                Text("Passage : " + PhoneScreenContent.format(s.segmentLength))
                Spacer()
                Text(PhoneScreenContent.format(s.end))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.07)))
    }

    private func handle(x: CGFloat, height: CGFloat, onMove: @escaping (CGFloat) -> Void) -> some View {
        Capsule()
            .fill(.white)
            .frame(width: 10, height: height * 0.6)
            .shadow(radius: 3)
            .frame(width: 34, height: height)
            .contentShape(Rectangle())
            .offset(x: x - 17)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("wave")).onChanged { g in onMove(g.location.x) })
    }

    private var transport: some View {
        HStack(spacing: 36) {
            Button { preview.rewind() } label: {
                Image(systemName: "backward.end.fill").font(.title2)
            }
            .accessibilityLabel("Revenir au début")
            Button { preview.toggle() } label: {
                Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(.white.opacity(0.16)))
            }
            .accessibilityLabel(preview.isPlaying ? "Pause" : "Écouter le remix")
            Text(PhoneScreenContent.format(preview.position))
                .font(.headline.monospacedDigit())
                .frame(width: 50)
        }
        .buttonStyle(PressStyle())
        .padding(.vertical, 4)
    }

    // MARK: Réglages

    private func card<Content: View>(_ title: String, _ symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.07)))
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(text).font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
            }
            Slider(value: value, in: range).tint(.white)
        }
    }

    private func chip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(on ? Color.black : Color.white)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.12)))
        }
        .buttonStyle(PressStyle(circle: false))
    }

    private func speedCard(_ s: Binding<RemixSettings>) -> some View {
        card("Vitesse et tonalité", "gauge.with.dots.needle.33percent") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("Slowed", on: abs(s.wrappedValue.speed - 0.85) < 0.01) { s.wrappedValue.speed = 0.85; s.wrappedValue.pitchFollowsSpeed = true }
                    chip("Normal", on: abs(s.wrappedValue.speed - 1) < 0.01) { s.wrappedValue.speed = 1 }
                    chip("Sped up", on: abs(s.wrappedValue.speed - 1.2) < 0.01) { s.wrappedValue.speed = 1.2; s.wrappedValue.pitchFollowsSpeed = true }
                    chip("Nightcore", on: abs(s.wrappedValue.speed - 1.3) < 0.01) { s.wrappedValue.speed = 1.3; s.wrappedValue.pitchFollowsSpeed = true }
                }
            }
            slider("Vitesse", s.speed, 0.5...1.5, String(format: "×%.2f", s.wrappedValue.speed))
            Toggle("La tonalité suit la vitesse", isOn: s.pitchFollowsSpeed)
                .font(.subheadline)
            slider("Tonalité", s.semitones, -12...12,
                   (s.wrappedValue.semitones >= 0 ? "+" : "") + String(format: "%.0f", s.wrappedValue.semitones) + " demi-tons")
        }
    }

    private func effectsCard(_ s: Binding<RemixSettings>) -> some View {
        card("Effets", "sparkles") {
            slider("Réverbe", s.reverb, 0...1, "\(Int(s.wrappedValue.reverb * 100)) %")
            slider("Écho", s.echo, 0...1, "\(Int(s.wrappedValue.echo * 100)) %")
            slider("Basses", s.bass, 0...1, "+\(Int(s.wrappedValue.bass * 12)) dB")
            slider("Son étouffé (sous l’eau)", s.muffle, 0...1, "\(Int(s.wrappedValue.muffle * 100)) %")
        }
    }

    private func loopCard(_ s: Binding<RemixSettings>) -> some View {
        card("Boucle et fondus", "repeat") {
            Stepper("Passage répété \(s.wrappedValue.loops) fois", value: s.loops, in: 1...8)
                .font(.subheadline)
            slider("Fondu au début", s.fadeIn, 0...8, String(format: "%.1f s", s.wrappedValue.fadeIn))
            slider("Fondu à la fin", s.fadeOut, 0...8, String(format: "%.1f s", s.wrappedValue.fadeOut))
        }
    }

    private func beatCard(_ s: Binding<RemixSettings>) -> some View {
        card("Beat", "metronome.fill") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(BeatPattern.allCases) { p in
                        chip(p.label, on: s.wrappedValue.beat == p) {
                            s.wrappedValue.beat = p
                            if p != .none { s.wrappedValue.bpm = p.defaultBPM }
                        }
                    }
                }
            }
            if s.wrappedValue.beat != .none {
                slider("Tempo", s.bpm, 60...180, "\(Int(s.wrappedValue.bpm)) BPM")
                HStack {
                    Button {
                        tapTempo(s)
                    } label: {
                        Label("Taper le tempo", systemImage: "hand.tap.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Capsule().fill(.white.opacity(0.12)))
                    }
                    .buttonStyle(PressStyle(circle: false))
                    Text("Tape en rythme sur le son").font(.caption).foregroundStyle(.white.opacity(0.5))
                }
                slider("Volume du beat", s.beatVolume, 0...1, "\(Int(s.wrappedValue.beatVolume * 100)) %")
            }
        }
    }

    /// Le tempo calculé à partir des derniers touchers.
    private func tapTempo(_ s: Binding<RemixSettings>) {
        let now = Date()
        taps = taps.filter { now.timeIntervalSince($0) < 3 } + [now]
        guard taps.count >= 3 else { return }
        let gaps = zip(taps.dropFirst(), taps).map { $0.timeIntervalSince($1) }
        let avg = gaps.reduce(0, +) / Double(gaps.count)
        guard avg > 0 else { return }
        s.wrappedValue.bpm = min(180, max(60, (60 / avg).rounded()))
    }

    private func exportCard(_ t: Track) -> some View {
        card("Créer le remix", "square.and.arrow.down.fill") {
            TextField("Nom du remix", text: $name)
                .textFieldStyle(.roundedBorder)
            Button {
                export(t)
            } label: {
                Text("Créer et ajouter à ma bibliothèque")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(PressStyle(circle: false))
            .disabled(exporting || !preview.ready)
            Text("Le son d’origine ne change pas : le remix est un nouveau morceau, rangé dans l’album « Remixes » avec la même pochette.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func export(_ t: Track) {
        preview.pause()
        exporting = true
        progress = 0
        let settings = preview.settings
        let source = library.audioURL(t)
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? t.title + " (Remix)" : name
        Task {
            let result: URL? = await Task.detached(priority: .userInitiated) {
                try? RemixGraph.render(settings, source: source) { p in
                    Task { @MainActor in progress = p }
                }
            }.value
            if let url = result, await library.addRemix(url, from: t, title: title) != nil {
                exporting = false
                dismiss()
            } else {
                exporting = false
                failed = true
            }
        }
    }
}

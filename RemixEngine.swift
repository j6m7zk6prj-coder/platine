import AVFoundation

/// Les réglages d'un remix. Le fichier d'origine n'est jamais modifié : le remix est un nouveau fichier.
struct RemixSettings: Equatable {
    /// Passage gardé, en secondes dans le son d'origine.
    var start: Double = 0
    var end: Double = 0
    /// Nombre de fois que le passage est joué à la suite.
    var loops: Int = 1
    /// Vitesse (0,5 à 1,5).
    var speed: Double = 1
    /// La tonalité suit la vitesse (son « slowed » ou « sped up »).
    var pitchFollowsSpeed = true
    /// Tonalité en demi-tons, en plus.
    var semitones: Double = 0
    var reverb: Double = 0
    var echo: Double = 0
    var bass: Double = 0
    /// Filtre « sous l'eau » : 0 = ouvert, 1 = très étouffé.
    var muffle: Double = 0
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var beat: BeatPattern = .none
    var bpm: Double = 140
    var beatVolume: Double = 0.7

    var segmentLength: Double { max(0.1, end - start) }
    /// Durée du remix tel qu'on l'entend.
    var outputLength: Double { segmentLength * Double(loops) / speed }

    /// Volume du remix à un instant (fondus d'entrée et de sortie).
    func gain(at t: Double) -> Float {
        var g = 1.0
        if fadeIn > 0.05 { g = min(g, max(0, t / fadeIn)) }
        if fadeOut > 0.05 { g = min(g, max(0, (outputLength - t) / fadeOut)) }
        return Float(g)
    }

    var pitchCents: Float {
        let follow = pitchFollowsSpeed ? 1200 * log2(speed) : 0
        return Float(follow + semitones * 100)
    }
}

/// Rythmes de batterie à poser sous le son.
enum BeatPattern: String, CaseIterable, Identifiable {
    case none, trap, drill, boomBap, jersey, house

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Aucun"
        case .trap: return "Trap"
        case .drill: return "Drill"
        case .boomBap: return "Boom bap"
        case .jersey: return "Jersey"
        case .house: return "House"
        }
    }
    var defaultBPM: Double {
        switch self {
        case .none: return 140
        case .trap: return 140
        case .drill: return 142
        case .boomBap: return 90
        case .jersey: return 140
        case .house: return 124
        }
    }

    /// Les 16 cases d'une mesure, pour chaque instrument.
    var steps: (kick: [Int], snare: [Int], clap: [Int], hat: [Int], bass808: [Int]) {
        switch self {
        case .none: return ([], [], [], [], [])
        case .trap: return ([0, 10], [], [8], [0, 2, 4, 6, 8, 10, 12, 13, 14, 15], [0, 10])
        case .drill: return ([0, 7, 10], [8], [], [0, 3, 6, 8, 11, 14], [0, 7, 10])
        case .boomBap: return ([0, 7, 10], [4, 12], [], [0, 2, 4, 6, 8, 10, 12, 14], [])
        case .jersey: return ([0, 3, 6, 8, 11, 14], [], [4, 12], [2, 6, 10, 14], [0, 8])
        case .house: return ([0, 4, 8, 12], [], [4, 12], [2, 6, 10, 14], [])
        }
    }
}

/// Construit et pilote la chaîne audio du remix (aperçu en direct et export).
enum RemixGraph {
    final class Nodes {
        let player = AVAudioPlayerNode()
        let drums = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        let eq = AVAudioUnitEQ(numberOfBands: 2)
        let delay = AVAudioUnitDelay()
        let reverb = AVAudioUnitReverb()
    }

    static func build(_ engine: AVAudioEngine, file: AVAudioFile) -> Nodes {
        let n = Nodes()
        for node in [n.player, n.drums, n.timePitch, n.eq, n.delay, n.reverb] as [AVAudioNode] {
            engine.attach(node)
        }
        let format = file.processingFormat
        engine.connect(n.player, to: n.timePitch, format: format)
        engine.connect(n.timePitch, to: n.eq, format: format)
        engine.connect(n.eq, to: n.delay, format: format)
        engine.connect(n.delay, to: n.reverb, format: format)
        engine.connect(n.reverb, to: engine.mainMixerNode, format: format)
        let drumFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)
        engine.connect(n.drums, to: engine.mainMixerNode, format: drumFormat)
        n.reverb.loadFactoryPreset(.largeHall)
        n.delay.delayTime = 0.33
        n.delay.feedback = 35
        n.delay.lowPassCutoff = 6000
        let bassBand = n.eq.bands[0]
        bassBand.filterType = .lowShelf
        bassBand.frequency = 110
        bassBand.bypass = false
        let filterBand = n.eq.bands[1]
        filterBand.filterType = .lowPass
        filterBand.bandwidth = 0.6
        filterBand.bypass = false
        return n
    }

    /// Applique les réglages qui changent en direct (vitesse, effets…).
    static func apply(_ s: RemixSettings, to n: Nodes) {
        n.timePitch.rate = Float(s.speed)
        n.timePitch.pitch = s.pitchCents
        n.reverb.wetDryMix = Float(s.reverb * 55)
        n.delay.wetDryMix = Float(s.echo * 45)
        n.eq.bands[0].gain = Float(s.bass * 12)
        // De 20 000 Hz (ouvert) à 350 Hz (étouffé), sur une échelle qui sonne naturelle.
        n.eq.bands[1].frequency = Float(20000 * pow(350.0 / 20000.0, s.muffle))
        n.drums.volume = s.beat == .none ? 0 : Float(s.beatVolume)
    }

    /// Prépare le passage choisi (répété) et la batterie, prêts à démarrer ensemble.
    static func schedule(_ s: RemixSettings, file: AVAudioFile, on n: Nodes) {
        let sr = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, s.start) * sr)
        let frames = AVAudioFrameCount(max(1, min(Double(file.length - startFrame), s.segmentLength * sr)))
        for _ in 0..<max(1, s.loops) {
            n.player.scheduleSegment(file, startingFrame: startFrame, frameCount: frames, at: nil)
        }
        if s.beat != .none, let bar = DrumSynth.bar(s.beat, bpm: s.bpm, sampleRate: sr) {
            n.drums.scheduleBuffer(bar, at: nil, options: .loops)
        }
    }

    /// Crée le fichier du remix (plus vite que le temps réel), dans un dossier temporaire.
    static func render(_ s: RemixSettings, source: URL, progress: @escaping (Double) -> Void) throws -> URL {
        let file = try AVAudioFile(forReading: source)
        let engine = AVAudioEngine()
        let n = build(engine, file: file)
        apply(s, to: n)
        let sr = file.processingFormat.sampleRate
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: outFormat, maximumFrameCount: 4096)
        try engine.start()
        schedule(s, file: file, on: n)
        n.player.play()
        n.drums.play()

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("Remix-" + UUID().uuidString + ".m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000
        ]
        let outFile = try AVAudioFile(forWriting: out, settings: settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw RemixError.failed
        }
        let total = AVAudioFramePosition(s.outputLength * sr)
        while engine.manualRenderingSampleTime < total {
            let left = total - engine.manualRenderingSampleTime
            let count = AVAudioFrameCount(min(Int64(buffer.frameCapacity), left))
            let t = Double(engine.manualRenderingSampleTime) / sr
            engine.mainMixerNode.outputVolume = s.gain(at: t)
            let status = try engine.renderOffline(count, to: buffer)
            switch status {
            case .success:
                try outFile.write(from: buffer)
            case .error:
                throw RemixError.failed
            default:
                break
            }
            progress(Double(engine.manualRenderingSampleTime) / Double(max(total, 1)))
        }
        n.player.stop()
        n.drums.stop()
        engine.stop()
        return out
    }

    enum RemixError: Error { case failed }
}

/// Batterie fabriquée par l'app : grosse caisse, caisse claire, clap, charleston et basse 808.
enum DrumSynth {
    static func bar(_ pattern: BeatPattern, bpm: Double, sampleRate sr: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else { return nil }
        let stepLength = 60.0 / bpm / 4
        let frames = AVAudioFrameCount(stepLength * 16 * sr)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let left = buffer.floatChannelData?[0], let right = buffer.floatChannelData?[1] else { return nil }
        buffer.frameLength = frames
        let n = Int(frames)
        for i in 0..<n { left[i] = 0; right[i] = 0 }
        var noise: UInt32 = 2463534242
        func white() -> Float {
            noise ^= noise << 13; noise ^= noise >> 17; noise ^= noise << 5
            return Float(Int32(bitPattern: noise)) / Float(Int32.max)
        }
        func add(at step: Int, length: Double, pan: Float = 0, _ voice: (Double) -> Float) {
            let begin = Int(Double(step) * stepLength * sr)
            let count = Int(length * sr)
            for k in 0..<count {
                // La fin de la mesure reboucle au début (un 808 long ne se coupe pas net).
                let idx = (begin + k) % n
                let v = voice(Double(k) / sr)
                left[idx] += v * (1 - max(0, pan))
                right[idx] += v * (1 + min(0, pan))
            }
        }
        let st = pattern.steps
        for s in st.kick {
            add(at: s, length: 0.28) { t in
                let f = 50 + 120 * exp(-t * 35)
                return Float(sin(2 * .pi * f * t) * exp(-t * 14)) * 0.9
            }
        }
        for s in st.bass808 {
            let len = min(0.9, stepLength * 6)
            add(at: s, length: len) { t in
                let f = 44 + 30 * exp(-t * 25)
                let env = min(1, t * 200) * exp(-t * 2.4)
                return Float(tanh(1.6 * sin(2 * .pi * f * t)) * env) * 0.55
            }
        }
        for s in st.snare {
            add(at: s, length: 0.22) { t in
                let tone = sin(2 * .pi * 190 * t) * exp(-t * 30) * 0.4
                return (white() * Float(exp(-t * 20)) * 0.5) + Float(tone)
            }
        }
        for s in st.clap {
            add(at: s, length: 0.25) { t in
                // Trois petits claquements rapprochés, comme des mains.
                let bursts = exp(-fmod(t, 0.012) * 300) * (t < 0.036 ? 1 : 0)
                return white() * Float((bursts * 0.6 + exp(-t * 18) * 0.35))
            }
        }
        for (i, s) in st.hat.enumerated() {
            let pan: Float = i % 2 == 0 ? -0.25 : 0.25
            add(at: s, length: 0.05, pan: pan) { t in
                white() * Float(exp(-t * 90)) * 0.18
            }
        }
        // Évite toute saturation.
        var peak: Float = 0
        for i in 0..<n { peak = max(peak, abs(left[i]), abs(right[i])) }
        if peak > 0.95 {
            let g = 0.95 / peak
            for i in 0..<n { left[i] *= g; right[i] *= g }
        }
        return buffer
    }
}

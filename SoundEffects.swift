import AVFoundation
import MediaToolbox

/// Effets d'écoute : slowed, sped up, réverbe… Le fichier audio n'est jamais modifié :
/// la vitesse est celle du lecteur, et la réverbe est calculée en direct pendant la lecture.
enum SoundEffect: String, CaseIterable, Identifiable {
    case original, slowed, slowedReverb, superSlowed, spedUp, nightcore, room, hall, cathedral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .slowed: return "Slowed"
        case .slowedReverb: return "Slowed + reverb"
        case .superSlowed: return "Super slowed"
        case .spedUp: return "Sped up"
        case .nightcore: return "Nightcore"
        case .room: return "Pièce"
        case .hall: return "Salle de concert"
        case .cathedral: return "Cathédrale"
        }
    }

    var subtitle: String {
        switch self {
        case .original: return "Le son tel quel"
        case .slowed: return "Plus lent et plus grave"
        case .slowedReverb: return "Lent, grave, avec de l’écho"
        case .superSlowed: return "Très lent, très planant"
        case .spedUp: return "Plus rapide et plus aigu"
        case .nightcore: return "Très rapide et aigu"
        case .room: return "Petite réverbe chaleureuse"
        case .hall: return "Comme dans une grande salle"
        case .cathedral: return "Écho long et profond"
        }
    }

    var symbol: String {
        switch self {
        case .original: return "waveform"
        case .slowed: return "tortoise.fill"
        case .slowedReverb: return "moon.stars.fill"
        case .superSlowed: return "cloud.moon.fill"
        case .spedUp: return "hare.fill"
        case .nightcore: return "bolt.fill"
        case .room: return "sofa.fill"
        case .hall: return "building.columns.fill"
        case .cathedral: return "sparkles"
        }
    }

    /// Vitesse (multipliée par ta vitesse de lecture habituelle).
    var rate: Double {
        switch self {
        case .slowed: return 0.86
        case .slowedReverb: return 0.82
        case .superSlowed: return 0.72
        case .spedUp: return 1.2
        case .nightcore: return 1.3
        default: return 1
        }
    }

    /// Vrai si la hauteur suit la vitesse (comme un vinyle ralenti), ce qui fait le son « slowed ».
    var changesPitch: Bool { rate != 1 }

    /// Réglages de la réverbe (nil = pas de réverbe).
    var reverb: ReverbSettings? {
        switch self {
        case .original, .spedUp: return nil
        case .slowed: return ReverbSettings(wet: 0.16, room: 0.6, damp: 0.5, preDelay: 0.02)
        case .slowedReverb: return ReverbSettings(wet: 0.4, room: 0.88, damp: 0.35, preDelay: 0.035)
        case .superSlowed: return ReverbSettings(wet: 0.5, room: 0.94, damp: 0.3, preDelay: 0.045)
        case .nightcore: return ReverbSettings(wet: 0.08, room: 0.4, damp: 0.6, preDelay: 0.01)
        case .room: return ReverbSettings(wet: 0.22, room: 0.5, damp: 0.6, preDelay: 0.01)
        case .hall: return ReverbSettings(wet: 0.32, room: 0.83, damp: 0.42, preDelay: 0.03)
        case .cathedral: return ReverbSettings(wet: 0.46, room: 0.96, damp: 0.25, preDelay: 0.06)
        }
    }

    /// Les groupes affichés dans le choix des effets.
    static let speedGroup: [SoundEffect] = [.slowed, .slowedReverb, .superSlowed, .spedUp, .nightcore]
    static let reverbGroup: [SoundEffect] = [.room, .hall, .cathedral]
}

struct ReverbSettings {
    var wet: Float
    var room: Float
    var damp: Float
    var preDelay: Float
}

/// Les réglages lus en direct par le traitement audio.
struct ReverbParams {
    var wet: Float = 0
    var room: Float = 0.5
    var damp: Float = 0.5
    var preDelay: Float = 0
}

enum SoundEffects {
    nonisolated(unsafe) static let params: UnsafeMutablePointer<ReverbParams> = {
        let p = UnsafeMutablePointer<ReverbParams>.allocate(capacity: 1)
        p.initialize(to: ReverbParams())
        return p
    }()

    /// Applique la réverbe d'un effet, avec une intensité de 0 à 1 (0,5 = réglage d'origine de l'effet).
    static func apply(_ effect: SoundEffect, intensity: Double) {
        guard let r = effect.reverb else {
            params.pointee.wet = 0
            return
        }
        let factor = Float(min(1, max(0, intensity)) * 2)
        params.pointee.room = r.room
        params.pointee.damp = r.damp
        params.pointee.preDelay = r.preDelay
        params.pointee.wet = min(0.85, r.wet * factor)
    }

    /// Branche le traitement sur un morceau (il ne fait rien tant qu'aucune réverbe n'est choisie).
    @MainActor
    static func attach(to item: AVPlayerItem) {
        Task { @MainActor in
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first,
                  let mix = makeMix(track: track) else { return }
            item.audioMix = mix
        }
    }

    private static func makeMix(track: AVAssetTrack) -> AVAudioMix? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(params),
            init: reverbInit,
            finalize: reverbFinalize,
            prepare: reverbPrepare,
            unprepare: nil,
            process: reverbProcess)
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else { return nil }
        let input = AVMutableAudioMixInputParameters(track: track)
        input.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [input]
        return mix
    }
}

// MARK: - Réverbe (algorithme « Freeverb » : 8 filtres en peigne + 4 passe-tout par côté)

struct DelayLine {
    var buffer: UnsafeMutablePointer<Float>
    var size: Int
    var index = 0
    var store: Float = 0

    init(size: Int) {
        self.size = max(1, size)
        buffer = UnsafeMutablePointer<Float>.allocate(capacity: self.size)
        buffer.initialize(repeating: 0, count: self.size)
    }

    func free() { buffer.deallocate() }
    func clear() { buffer.update(repeating: 0, count: size) }

    /// Filtre en peigne amorti (la « queue » de la réverbe).
    mutating func comb(_ x: Float, feedback: Float, damp: Float) -> Float {
        let out = buffer[index]
        store = out * (1 - damp) + store * damp
        buffer[index] = x + store * feedback
        index += 1
        if index >= size { index = 0 }
        return out
    }

    /// Filtre passe-tout (diffuse l'écho pour qu'il soit doux, sans répétitions audibles).
    mutating func allpass(_ x: Float) -> Float {
        let b = buffer[index]
        buffer[index] = x + b * 0.5
        index += 1
        if index >= size { index = 0 }
        return b - x
    }
}

struct ReverbState {
    var params: UnsafeMutablePointer<ReverbParams>
    var ready = false
    var sampleRate: Double = 44100
    var combsL: [DelayLine] = []
    var combsR: [DelayLine] = []
    var allpassL: [DelayLine] = []
    var allpassR: [DelayLine] = []
    var pre: DelayLine?
    var preWrite = 0
    var wet: Float = 0
    var active = false

    mutating func build(sampleRate sr: Double) {
        freeAll()
        sampleRate = sr
        let k = sr / 44100
        let combTunings = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
        let allpassTunings = [556, 441, 341, 225]
        let spread = 23
        combsL = combTunings.map { DelayLine(size: Int(Double($0) * k)) }
        combsR = combTunings.map { DelayLine(size: Int(Double($0 + spread) * k)) }
        allpassL = allpassTunings.map { DelayLine(size: Int(Double($0) * k)) }
        allpassR = allpassTunings.map { DelayLine(size: Int(Double($0 + spread) * k)) }
        pre = DelayLine(size: Int(sr * 0.1) + 1)
        preWrite = 0
    }

    mutating func clearAll() {
        for d in combsL + combsR + allpassL + allpassR { d.clear() }
        pre?.clear()
        for i in combsL.indices { combsL[i].store = 0; combsR[i].store = 0 }
    }

    mutating func freeAll() {
        for d in combsL + combsR + allpassL + allpassR { d.free() }
        pre?.free()
        combsL = []; combsR = []; allpassL = []; allpassR = []
        pre = nil
    }
}

private let reverbInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    let state = UnsafeMutablePointer<ReverbState>.allocate(capacity: 1)
    let params = clientInfo?.assumingMemoryBound(to: ReverbParams.self) ?? SoundEffects.params
    state.initialize(to: ReverbState(params: params))
    storageOut.pointee = UnsafeMutableRawPointer(state)
}

private let reverbFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    let state = MTAudioProcessingTapGetStorage(tap).assumingMemoryBound(to: ReverbState.self)
    state.pointee.freeAll()
    state.deinitialize(count: 1)
    state.deallocate()
}

private let reverbPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    let state = MTAudioProcessingTapGetStorage(tap).assumingMemoryBound(to: ReverbState.self)
    let f = format.pointee
    let isFloat = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let nonInterleaved = (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    state.pointee.ready = isFloat && nonInterleaved && f.mChannelsPerFrame == 2 && f.mBitsPerChannel == 32
    state.pointee.build(sampleRate: f.mSampleRate > 0 ? f.mSampleRate : 44100)
}

private let reverbProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, bufferList, framesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut)
    guard status == noErr else { return }
    let s = MTAudioProcessingTapGetStorage(tap).assumingMemoryBound(to: ReverbState.self)
    guard s.pointee.ready, var pre = s.pointee.pre else { return }
    let p = s.pointee.params.pointee
    let target = p.wet
    // Pas de réverbe : le son passe sans être touché.
    if target < 0.001 && s.pointee.wet < 0.001 {
        if s.pointee.active { s.pointee.active = false }
        return
    }
    if !s.pointee.active {
        // On repart d'un écho vide (pas de reste d'un ancien morceau).
        s.pointee.clearAll()
        s.pointee.active = true
    }

    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    guard buffers.count >= 2,
          let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
          let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
    let n = Int(framesOut.pointee)
    guard n > 0 else { return }

    let feedback = p.room * 0.28 + 0.7
    let damp = p.damp * 0.4
    let preSamples = min(pre.size - 1, max(0, Int(Double(p.preDelay) * s.pointee.sampleRate)))
    var wet = s.pointee.wet
    // L'intensité change en douceur : jamais de clic quand on change d'effet.
    let step = (target - wet) / Float(n)
    let width: Float = 1

    for i in 0..<n {
        wet += step
        let l = left[i], r = right[i]
        // Petit délai avant l'écho : donne la taille de la pièce.
        pre.buffer[pre.index] = (l + r) * 0.015
        var read = pre.index - preSamples
        if read < 0 { read += pre.size }
        let input = pre.buffer[read]
        pre.index += 1
        if pre.index >= pre.size { pre.index = 0 }

        var outL: Float = 0, outR: Float = 0
        for c in 0..<s.pointee.combsL.count {
            outL += s.pointee.combsL[c].comb(input, feedback: feedback, damp: damp)
            outR += s.pointee.combsR[c].comb(input, feedback: feedback, damp: damp)
        }
        for a in 0..<s.pointee.allpassL.count {
            outL = s.pointee.allpassL[a].allpass(outL)
            outR = s.pointee.allpassR[a].allpass(outR)
        }
        let wet1 = wet * 3 * (width / 2 + 0.5)
        let wet2 = wet * 3 * ((1 - width) / 2)
        // Le son d'origine reste bien présent ; il baisse à peine quand l'écho augmente.
        let dry = 1 - wet * 0.45
        left[i] = l * dry + outL * wet1 + outR * wet2
        right[i] = r * dry + outR * wet1 + outL * wet2
    }
    s.pointee.pre = pre
    s.pointee.wet = target
}

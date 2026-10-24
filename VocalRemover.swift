import AVFoundation
import MediaToolbox

/// Mode instrumental (comme « Apple Music Sing ») : baisse la voix en direct pendant la lecture.
///
/// Le fichier audio n'est jamais modifié : le son est traité au moment où il est joué.
/// La voix est en général au centre du mélange ; on retire ce qui est commun aux deux côtés,
/// seulement dans les fréquences de la voix (environ 160 Hz à 7 kHz), pour garder les basses et la batterie.
enum VocalRemover {
    /// Niveau de réduction de la voix : 0 = voix normale, 1 = voix retirée au maximum.
    /// Lu directement par le traitement audio (sans attendre le fil principal).
    nonisolated(unsafe) static let level: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        p.initialize(to: 0)
        return p
    }()

    static func setLevel(_ value: Double) {
        level.pointee = Float(min(1, max(0, value)))
    }

    /// Branche le traitement sur un morceau (sans effet tant que le niveau est à 0).
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
            clientInfo: UnsafeMutableRawPointer(level),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: nil,
            process: tapProcess)
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else { return nil }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}

// MARK: - Filtres

/// Filtre du second ordre (formules classiques « RBJ »).
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    static func make(lowpass: Bool, frequency: Double, sampleRate: Double, q: Double = 0.707) -> Biquad {
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q)
        let c = cos(w)
        let a0 = 1 + alpha
        var f = Biquad()
        if lowpass {
            f.b0 = Float((1 - c) / 2 / a0)
            f.b1 = Float((1 - c) / a0)
            f.b2 = f.b0
        } else {
            f.b0 = Float((1 + c) / 2 / a0)
            f.b1 = Float(-(1 + c) / a0)
            f.b2 = f.b0
        }
        f.a1 = Float(-2 * c / a0)
        f.a2 = Float((1 - alpha) / a0)
        return f
    }
}

struct VocalTapState {
    var level: UnsafeMutablePointer<Float>
    var current: Float = 0
    var ready = false
    var high1 = Biquad(), high2 = Biquad()
    var low1 = Biquad(), low2 = Biquad()
}

// MARK: - Fonctions appelées par le système audio (aucune capture : ce sont des fonctions C)

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    let state = UnsafeMutablePointer<VocalTapState>.allocate(capacity: 1)
    let level = clientInfo?.assumingMemoryBound(to: Float.self) ?? VocalRemover.level
    state.initialize(to: VocalTapState(level: level))
    storageOut.pointee = UnsafeMutableRawPointer(state)
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    let state = MTAudioProcessingTapGetStorage(tap).assumingMemoryBound(to: VocalTapState.self)
    state.deinitialize(count: 1)
    state.deallocate()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    let state = MTAudioProcessingTapGetStorage(tap).assumingMemoryBound(to: VocalTapState.self)
    let f = format.pointee
    let isFloat = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let nonInterleaved = (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    state.pointee.ready = isFloat && nonInterleaved && f.mChannelsPerFrame == 2 && f.mBitsPerChannel == 32
    let sr = f.mSampleRate > 0 ? f.mSampleRate : 44100
    state.pointee.high1 = .make(lowpass: false, frequency: 160, sampleRate: sr)
    state.pointee.high2 = .make(lowpass: false, frequency: 160, sampleRate: sr)
    state.pointee.low1 = .make(lowpass: true, frequency: 7000, sampleRate: sr)
    state.pointee.low2 = .make(lowpass: true, frequency: 7000, sampleRate: sr)
}

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, bufferList, framesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut)
    guard status == noErr else { return }
    let state = MTAudioProcessingTapGetStorage(tap).assumingMemoryBound(to: VocalTapState.self)
    guard state.pointee.ready else { return }
    let target = state.pointee.level.pointee
    // Voix normale : le son passe sans être touché.
    if target < 0.001 && state.pointee.current < 0.001 { return }

    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    guard buffers.count >= 2,
          let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
          let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
    let n = Int(framesOut.pointee)
    guard n > 0 else { return }

    var amount = state.pointee.current
    // Le niveau change en douceur (pas de clic quand on bouge le curseur).
    let step = (target - amount) / Float(n)
    for i in 0..<n {
        amount += step
        let mid = 0.5 * (left[i] + right[i])
        var voice = state.pointee.high1.process(mid)
        voice = state.pointee.high2.process(voice)
        voice = state.pointee.low1.process(voice)
        voice = state.pointee.low2.process(voice)
        // Retirer le centre baisse un peu le volume : on compense légèrement.
        let gain: Float = 1 + 0.2 * amount
        left[i] = (left[i] - amount * voice) * gain
        right[i] = (right[i] - amount * voice) * gain
    }
    state.pointee.current = target
}

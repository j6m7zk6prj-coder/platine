import Foundation
import AVFoundation

/// Effets audio et traitement bas niveau (MTAudioProcessingTap / Reverb / Speed).
final class SoundEffects {
    static let shared = SoundEffects()
    
    enum ReverbPreset: String, CaseIterable, Identifiable {
        case none = "Aucun"
        case room = "Pièce"
        case hall = "Salle de concert"
        case cathedral = "Cathédrale"
        
        var id: String { rawValue }
    }
    
    private var engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var pitchNode = AVAudioUnitTimePitch()
    private var reverbNode = AVAudioUnitReverb()
    
    init() {
        setupEngine()
    }
    
    private func setupEngine() {
        engine.attach(playerNode)
        engine.attach(pitchNode)
        engine.attach(reverbNode)
        
        engine.connect(playerNode, to: pitchNode, format: nil)
        engine.connect(pitchNode, to: reverbNode, format: nil)
        engine.connect(reverbNode, to: engine.mainMixerNode, format: nil)
    }
    
    func setRate(_ rate: Float) {
        pitchNode.rate = rate
    }
    
    func setPitch(_ cents: Float) {
        pitchNode.pitch = cents
    }
    
    func setReverb(_ preset: ReverbPreset) {
        switch preset {
        case .none:
            reverbNode.bypass = true
        case .room:
            reverbNode.bypass = false
            reverbNode.loadFactoryPreset(.mediumRoom)
            reverbNode.wetDryMix = 35
        case .hall:
            reverbNode.bypass = false
            reverbNode.loadFactoryPreset(.largeHall)
            reverbNode.wetDryMix = 50
        case .cathedral:
            reverbNode.bypass = false
            reverbNode.loadFactoryPreset(.cathedral)
            reverbNode.wetDryMix = 70
        }
    }
}

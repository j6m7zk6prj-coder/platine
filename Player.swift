import AVFoundation
import MediaPlayer
import Observation
import SwiftUI
import UIKit

/// Lecteur audio : file d'attente, fondus, vitesse, minuterie, écran verrouillé, AirPods.
@MainActor
@Observable
final class Player {
    enum RepeatMode: Int { case off, all, one }

    /// Ordre de lecture actuel (mélangé si l'aléatoire est actif).
    private(set) var queue: [UUID] = []
    private(set) var index: Int = 0
    /// Morceaux ajoutés avec « Lire ensuite » / « Lire plus tard ».
    private(set) var upNext: [UUID] = []
    private(set) var currentID: UUID?
    /// Intention de lecture (change tout de suite, même pendant un fondu).
    private(set) var isPlaying = false
    var currentTime: Double = 0
    private(set) var duration: Double = 0
    var isScrubbing = false
    private(set) var shuffle: Bool = UserDefaults.standard.bool(forKey: "shuffle")
    var repeatMode: RepeatMode = RepeatMode(rawValue: UserDefaults.standard.integer(forKey: "repeat")) ?? .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeat") }
    }
    private(set) var sleepEndDate: Date?
    private(set) var sleepAtTrackEnd = false

    var sleepActive: Bool { sleepEndDate != nil || sleepAtTrackEnd }

    /// Ce qui sera joué ensuite, dans l'ordre.
    var upcomingInQueue: [Int] {
        index + 1 < queue.count ? Array((index + 1)..<queue.count) : []
    }

    private let library: Library
    private let settings: AppSettings
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var originalQueue: [UUID] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var manualFade = false
    @ObservationIgnored private var resumeAfterInterruption = false

    init(library: Library, settings: AppSettings) {
        self.library = library
        self.settings = settings
        player.automaticallyWaitsToMinimizeStalling = false
        player.defaultRate = Float(settings.playbackSpeed)
        configureSession()
        configureRemoteCommands()
        observe()
    }

    // MARK: Lancer la lecture

    /// Joue une liste de morceaux à partir de l'un d'eux.
    func play(ids: [UUID], startAt: UUID? = nil, shuffled: Bool? = nil) {
        guard !ids.isEmpty else { return }
        if let shuffled {
            shuffle = shuffled
            UserDefaults.standard.set(shuffled, forKey: "shuffle")
        }
        let start = startAt ?? (shuffle ? (ids.randomElement() ?? ids[0]) : ids[0])
        originalQueue = ids
        if shuffle {
            queue = [start] + ids.filter { $0 != start }.shuffled()
            index = 0
        } else {
            queue = ids
            index = ids.firstIndex(of: start) ?? 0
        }
        load(queue[index], autoplay: true)
    }

    func play(_ id: UUID) { play(ids: [id]) }

    func togglePlay() { isPlaying ? pause() : resume() }

    func resume() {
        if player.currentItem == nil {
            if let id = currentID { load(id, autoplay: true); return }
            play(ids: library.tracks.map(\.id))
            return
        }
        fadeTask?.cancel()
        startPlayback()
    }

    func pause(fade: Double = 0.22) {
        isPlaying = false
        updateNowPlaying()
        fadeTask?.cancel()
        manualFade = true
        fadeTask = Task { [weak self] in
            guard let self else { return }
            await self.fade(to: 0, duration: fade)
            if !Task.isCancelled {
                self.player.pause()
                self.manualFade = false
                self.updateNowPlaying()
            }
        }
    }

    func next() { advance(auto: false) }

    func previous() {
        if currentTime > 3 || queue.isEmpty { seek(to: 0); return }
        if index > 0 {
            index -= 1
        } else if repeatMode == .all {
            index = queue.count - 1
        } else {
            seek(to: 0)
            return
        }
        load(queue[index], autoplay: isPlaying)
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
    }

    func cycleRepeat() {
        repeatMode = RepeatMode(rawValue: (repeatMode.rawValue + 1) % 3) ?? .off
    }

    func setShuffle(_ on: Bool) {
        guard on != shuffle else { return }
        shuffle = on
        UserDefaults.standard.set(on, forKey: "shuffle")
        guard let cur = currentID, !queue.isEmpty else { return }
        if on {
            originalQueue = queue
            let rest = queue.enumerated().filter { $0.offset != index }.map(\.element).shuffled()
            queue = [cur] + rest
            index = 0
        } else if !originalQueue.isEmpty {
            queue = originalQueue
            index = queue.firstIndex(of: cur) ?? 0
        }
    }

    func setSpeed(_ speed: Double) {
        settings.playbackSpeed = speed
        player.defaultRate = Float(speed)
        if isPlaying { player.rate = Float(speed) }
        updateNowPlaying()
    }

    // MARK: File d'attente

    func playNext(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        if currentID == nil { play(ids: ids); return }
        upNext.insert(contentsOf: ids, at: 0)
        library.message = ids.count > 1 ? "\(ids.count) morceaux lus ensuite" : "Sera lu ensuite"
    }

    func playLater(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        if currentID == nil { play(ids: ids); return }
        upNext.append(contentsOf: ids)
        library.message = ids.count > 1 ? "\(ids.count) morceaux ajoutés à la file" : "Ajouté à la file d’attente"
    }

    func removeUpNext(at offsets: IndexSet) { upNext.remove(atOffsets: offsets) }

    func moveUpNext(from: IndexSet, to: Int) { upNext.move(fromOffsets: from, toOffset: to) }

    func clearUpNext() { upNext.removeAll() }

    func playUpNext(at i: Int) {
        guard upNext.indices.contains(i) else { return }
        let id = upNext.remove(at: i)
        if queue.isEmpty {
            queue = [id]
            index = 0
        } else {
            queue.insert(id, at: index + 1)
            index += 1
        }
        load(id, autoplay: true)
    }

    func jump(toQueueIndex i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        load(queue[i], autoplay: true)
    }

    /// À appeler quand des morceaux sont retirés de la bibliothèque.
    func removed(_ ids: Set<UUID>) {
        upNext.removeAll { ids.contains($0) }
        originalQueue.removeAll { ids.contains($0) }
        if let id = currentID, ids.contains(id) {
            stopAll()
            return
        }
        queue.removeAll { ids.contains($0) }
        if let id = currentID { index = queue.firstIndex(of: id) ?? 0 }
    }

    func stopAll() {
        fadeTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []
        upNext = []
        originalQueue = []
        index = 0
        currentID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        updateNowPlaying()
    }

    // MARK: Minuterie de sommeil

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        sleepAtTrackEnd = false
        sleepEndDate = nil
        guard let minutes, minutes > 0 else { return }
        sleepEndDate = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.sleepEndDate = nil
            if self.isPlaying { self.pause(fade: 4) }
        }
        library.message = "Arrêt dans \(minutes) min"
    }

    func setSleepAtTrackEnd() {
        sleepTask?.cancel()
        sleepEndDate = nil
        sleepAtTrackEnd = true
        library.message = "Arrêt à la fin du morceau"
    }

    // MARK: Chargement et fondus

    private func load(_ id: UUID, autoplay: Bool) {
        guard let track = library.track(id) else {
            // Morceau supprimé : on passe au suivant.
            if let i = queue.firstIndex(of: id) {
                queue.remove(at: i)
                if i <= index && index > 0 { index -= 1 }
            }
            if queue.indices.contains(index) { load(queue[index], autoplay: autoplay) } else { stopAll() }
            return
        }
        let fadeOut = isPlaying && player.rate > 0
        fadeTask?.cancel()
        currentID = id
        duration = track.duration
        manualFade = true
        fadeTask = Task { [weak self] in
            guard let self else { return }
            if fadeOut { await self.fade(to: 0, duration: 0.18) }
            if Task.isCancelled { return }
            let item = AVPlayerItem(url: self.library.audioURL(track))
            item.audioTimePitchAlgorithm = .timeDomain
            self.player.replaceCurrentItem(with: item)
            self.currentTime = 0
            if autoplay {
                self.library.recordPlay(id)
                self.startPlayback()
            } else {
                self.isPlaying = false
                self.player.pause()
                self.manualFade = false
            }
            self.updateNowPlaying()
            if let d = try? await item.asset.load(.duration), d.seconds.isFinite, d.seconds > 0, self.currentID == id {
                self.duration = d.seconds
                self.updateNowPlaying()
            }
        }
    }

    private func startPlayback() {
        isPlaying = true
        try? AVAudioSession.sharedInstance().setActive(true)
        player.volume = 0
        player.defaultRate = Float(settings.playbackSpeed)
        player.play()
        updateNowPlaying()
        manualFade = true
        fadeTask = Task { [weak self] in
            guard let self else { return }
            await self.fade(to: 1, duration: 0.35)
            if !Task.isCancelled { self.manualFade = false }
        }
    }

    private func fade(to target: Float, duration: Double) async {
        let start = player.volume
        let steps = max(8, Int(duration * 40))
        for i in 1...steps {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: UInt64(duration / Double(steps) * 1_000_000_000))
            player.volume = start + (target - start) * Float(i) / Float(steps)
        }
    }

    /// Baisse le son à la fin d'un morceau et le remonte au début du suivant.
    private func applyTransitionFade() {
        guard !manualFade, isPlaying else { return }
        guard settings.fadeTransitions, duration > 0 else {
            if player.volume != 1 { player.volume = 1 }
            return
        }
        let f = max(1, settings.fadeDuration)
        var v: Float = 1
        if duration > f * 2.5 {
            let remaining = duration - currentTime
            if remaining < f {
                v = Float(max(0, remaining / f))
            } else if currentTime < f / 2 {
                v = Float(max(0.05, currentTime / (f / 2)))
            }
        }
        player.volume = v
    }

    private func advance(auto: Bool) {
        guard !queue.isEmpty || !upNext.isEmpty else { return }
        if !upNext.isEmpty {
            let id = upNext.removeFirst()
            if queue.isEmpty {
                queue = [id]
                index = 0
            } else {
                queue.insert(id, at: min(index + 1, queue.count))
                index += 1
            }
        } else if index + 1 < queue.count {
            index += 1
        } else if repeatMode == .all {
            index = 0
        } else if auto {
            isPlaying = false
            player.pause()
            seek(to: 0)
            updateNowPlaying()
            return
        } else {
            index = 0
        }
        load(queue[index], autoplay: auto ? true : isPlaying)
    }

    private func trackEnded() {
        if sleepAtTrackEnd {
            sleepAtTrackEnd = false
            isPlaying = false
            player.pause()
            seek(to: 0)
            updateNowPlaying()
            return
        }
        if repeatMode == .one {
            seek(to: 0)
            player.play()
            return
        }
        advance(auto: true)
    }

    // MARK: Système

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    private func observe() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite else { return }
                if !self.isScrubbing { self.currentTime = time.seconds }
                self.applyTransitionFade()
            }
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, let item, item === self.player.currentItem else { return }
                self.trackEnded()
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                guard let self, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
                if type == .began {
                    self.resumeAfterInterruption = self.isPlaying
                    self.isPlaying = false
                    self.updateNowPlaying()
                } else if AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume), self.resumeAfterInterruption {
                    self.resume()
                }
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                // Écouteurs débranchés ou AirPods retirés : pause, comme Musique.
                guard let self, self.settings.pauseOnDisconnect else { return }
                if AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable, self.isPlaying {
                    self.pause()
                }
            }
        })
    }

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = e.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }

    /// Met à jour l'écran verrouillé, le Centre de contrôle et la Dynamic Island.
    func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let id = currentID, let t = library.track(id) else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        let elapsed = player.currentTime().seconds
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.displayArtist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed.isFinite ? elapsed : 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? settings.playbackSpeed : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: settings.playbackSpeed
        ]
        if let img = library.image(for: t) {
            info[MPMediaItemPropertyArtwork] = Player.makeArtwork(img)
        }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    /// Hors du MainActor : le système demande l'image depuis un autre fil.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Lecteur audio : lecture en arrière-plan, fondus, écran verrouillé, AirPods.
@MainActor
@Observable
final class Player {
    enum RepeatMode: Int { case off, all, one }

    private(set) var currentID: UUID?
    /// Intention de lecture (change tout de suite, même pendant un fondu).
    private(set) var isPlaying = false
    var currentTime: Double = 0
    private(set) var duration: Double = 0
    var isScrubbing = false

    var shuffle: Bool = UserDefaults.standard.bool(forKey: "shuffle") {
        didSet { UserDefaults.standard.set(shuffle, forKey: "shuffle") }
    }
    var repeatMode: RepeatMode = RepeatMode(rawValue: UserDefaults.standard.integer(forKey: "repeat")) ?? .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeat") }
    }

    private let library: Library
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var resumeAfterInterruption = false

    init(library: Library) {
        self.library = library
        player.automaticallyWaitsToMinimizeStalling = false
        configureSession()
        configureRemoteCommands()
        observe()
    }

    // MARK: Commandes

    func play(_ id: UUID) { load(id, autoplay: true) }

    func togglePlay() { isPlaying ? pause() : resume() }

    func resume() {
        if player.currentItem == nil {
            if let first = library.tracks.first { load(first.id, autoplay: true) }
            return
        }
        fadeTask?.cancel()
        startPlayback()
    }

    func pause() {
        isPlaying = false
        updateNowPlaying()
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            guard let self else { return }
            await self.fade(to: 0, duration: 0.22)
            if !Task.isCancelled {
                self.player.pause()
                self.updateNowPlaying()
            }
        }
    }

    func next() { advance(auto: false) }

    func previous() {
        if currentTime > 3 { seek(to: 0); return }
        let queue = library.tracks.map(\.id)
        guard let id = currentID, let i = queue.firstIndex(of: id) else { return }
        let target = i > 0 ? queue[i - 1] : queue[queue.count - 1]
        load(target, autoplay: isPlaying)
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

    /// À appeler quand des morceaux sont retirés de la bibliothèque.
    func removed(_ ids: Set<UUID>) {
        guard let id = currentID, ids.contains(id) else { return }
        fadeTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        updateNowPlaying()
    }

    // MARK: Chargement et fondus

    private func load(_ id: UUID, autoplay: Bool) {
        guard let track = library.track(id) else { return }
        let fadeOut = isPlaying && player.rate > 0
        fadeTask?.cancel()
        currentID = id
        duration = track.duration
        fadeTask = Task { [weak self] in
            guard let self else { return }
            if fadeOut { await self.fade(to: 0, duration: 0.18) }
            if Task.isCancelled { return }
            let item = AVPlayerItem(url: self.library.audioURL(track))
            self.player.replaceCurrentItem(with: item)
            self.currentTime = 0
            if autoplay { self.startPlayback() } else { self.isPlaying = false; self.player.pause() }
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
        player.play()
        updateNowPlaying()
        fadeTask = Task { [weak self] in
            await self?.fade(to: 1, duration: 0.35)
        }
    }

    private func fade(to target: Float, duration: Double) async {
        let start = player.volume
        let steps = 14
        for i in 1...steps {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: UInt64(duration / Double(steps) * 1_000_000_000))
            player.volume = start + (target - start) * Float(i) / Float(steps)
        }
    }

    private func advance(auto: Bool) {
        let queue = library.tracks.map(\.id)
        guard let id = currentID, !queue.isEmpty else { return }
        var target: UUID?
        if shuffle && queue.count > 1 {
            target = queue.filter { $0 != id }.randomElement()
        } else if let i = queue.firstIndex(of: id) {
            if i + 1 < queue.count {
                target = queue[i + 1]
            } else if repeatMode == .all || !auto {
                target = queue.first
            }
        } else {
            target = queue.first
        }
        guard let target else {
            isPlaying = false
            player.pause()
            seek(to: 0)
            return
        }
        load(target, autoplay: auto ? true : isPlaying)
    }

    private func trackEnded() {
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
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing, time.seconds.isFinite else { return }
                self.currentTime = time.seconds
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
                if AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable, let self, self.isPlaying {
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
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
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

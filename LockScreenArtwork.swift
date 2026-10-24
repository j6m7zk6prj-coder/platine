import AVFoundation
import CoreImage
import ImageIO
import MediaPlayer
import UIKit

/// Pochettes animées sur l'écran verrouillé (iOS 26 et plus), comme dans Musique.
///
/// iOS demande un petit clip vidéo par forme : 3:4 (plein écran verrouillé de l'iPhone)
/// et 1:1 (carré). Les vidéos et GIF choisis comme pochette sont recadrés une seule fois,
/// en arrière-plan, puis gardés en cache. Le fichier original n'est jamais modifié.
@MainActor
final class LockScreenArtwork {
    static let shared = LockScreenArtwork()

    /// Appelé quand un clip vient d'être préparé, pour mettre à jour l'écran verrouillé.
    var onReady: () -> Void = {}

    private var artworks: [String: AnyObject] = [:]
    private var working: Set<String> = []
    /// Clips à préparer, un à la fois. iOS interdit l'encodage vidéo quand l'app est en arrière-plan
    /// (écran verrouillé) : la préparation se fait donc pendant que l'app est ouverte.
    private var queue: [Job] = []
    private var running = false
    private var observer: NSObjectProtocol?

    private struct Job {
        let id: String
        let source: URL
        let kind: ArtworkKind
        let shape: Shape
        let clip: URL
    }

    private init() {
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let me = LockScreenArtwork.shared
                // Les échecs dus à l'arrière-plan sont réessayés dès que l'app revient.
                me.failed.removeAll()
                me.pump()
                me.onReady()
            }
        }
    }

    /// Prépare à l'avance les clips d'une pochette animée (morceaux suivants, bibliothèque…).
    func warm(source: URL, kind: ArtworkKind) {
        #if compiler(>=6.2)
        guard #available(iOS 26.0, *), kind == .video || kind == .gif else { return }
        for key in MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys {
            let shape: Shape
            if key == MPNowPlayingInfoProperty3x4AnimatedArtwork { shape = .tall }
            else if key == MPNowPlayingInfoProperty1x1AnimatedArtwork { shape = .square }
            else { continue }
            let id = source.deletingPathExtension().lastPathComponent + "-" + shape.rawValue
            let clip = Self.folder.appendingPathComponent(id + ".mp4")
            if !FileManager.default.fileExists(atPath: clip.path) {
                prepare(id: id, source: source, kind: kind, shape: shape, clip: clip, urgent: false)
            }
        }
        #endif
    }
    /// Clips qui n'ont pas pu être préparés, avec l'heure de l'échec (on réessaie plus tard).
    private var failed: [String: Date] = [:]

    static let folder: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LockArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private enum Shape: String {
        case tall = "3x4", square = "1x1"
        var size: CGSize { self == .tall ? CGSize(width: 768, height: 1024) : CGSize(width: 1024, height: 1024) }
    }

    /// Les entrées à ajouter aux infos « En lecture ». Vide tant que le clip n'est pas prêt
    /// (il est alors préparé, puis `onReady` est appelé).
    func entries(source: URL, kind: ArtworkKind, preview: UIImage?) -> [String: Any] {
        #if compiler(>=6.2)
        guard #available(iOS 26.0, *), kind == .video || kind == .gif else { return [:] }
        var result: [String: Any] = [:]
        for key in MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys {
            let shape: Shape
            if key == MPNowPlayingInfoProperty3x4AnimatedArtwork { shape = .tall }
            else if key == MPNowPlayingInfoProperty1x1AnimatedArtwork { shape = .square }
            else { continue }

            let id = source.deletingPathExtension().lastPathComponent + "-" + shape.rawValue
            // Toujours le même objet pour une pochette donnée : sinon l'écran verrouillé se recharge sans arrêt.
            if let art = artworks[id] {
                result[key] = art
                continue
            }
            let clip = Self.folder.appendingPathComponent(id + ".mp4")
            if FileManager.default.fileExists(atPath: clip.path) {
                let art = Self.makeArtwork(id: id, preview: preview, clip: clip)
                artworks[id] = art
                result[key] = art
            } else {
                prepare(id: id, source: source, kind: kind, shape: shape, clip: clip, urgent: true)
            }
        }
        return result
        #else
        return [:]
        #endif
    }

    /// Vrai si le clip plein écran de cette pochette est déjà prêt.
    static func isPrepared(source: URL) -> Bool {
        let id = source.deletingPathExtension().lastPathComponent + "-3x4"
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(id + ".mp4").path)
    }

    /// Efface tous les clips (ils seront refaits au besoin).
    func clear() {
        artworks.removeAll()
        failed.removeAll()
        try? FileManager.default.removeItem(at: Self.folder)
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
    }

    static func cacheBytes() -> Int64 {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return items.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func prepare(id: String, source: URL, kind: ArtworkKind, shape: Shape, clip: URL, urgent: Bool) {
        guard !working.contains(id) else { return }
        if let when = failed[id], Date().timeIntervalSince(when) < 90 { return }
        let job = Job(id: id, source: source, kind: kind, shape: shape, clip: clip)
        if let i = queue.firstIndex(where: { $0.id == id }) {
            // Déjà prévu : le morceau en cours passe devant.
            if urgent { queue.remove(at: i); queue.insert(job, at: 0) }
        } else if urgent {
            queue.insert(job, at: 0)
        } else {
            queue.append(job)
        }
        pump()
    }

    private func pump() {
        guard !running, !queue.isEmpty, UIApplication.shared.applicationState == .active else { return }
        let job = queue.removeFirst()
        if FileManager.default.fileExists(atPath: job.clip.path) { pump(); return }
        running = true
        working.insert(job.id)
        let size = job.shape.size
        // Un peu de temps en plus si tu verrouilles l'iPhone pile pendant la préparation.
        let background = UIApplication.shared.beginBackgroundTask(withName: "LockArtwork")
        Task.detached(priority: .background) {
            let temp = job.clip.deletingLastPathComponent().appendingPathComponent(job.id + "-tmp.mp4")
            try? FileManager.default.removeItem(at: temp)
            var ok = false
            do {
                if job.kind == .gif {
                    try await Self.encodeGIF(job.source, to: temp, size: size)
                } else {
                    try await Self.cropVideo(job.source, to: temp, size: size)
                }
                try? FileManager.default.removeItem(at: job.clip)
                try FileManager.default.moveItem(at: temp, to: job.clip)
                ok = true
            } catch {
                try? FileManager.default.removeItem(at: temp)
            }
            await MainActor.run {
                let me = LockScreenArtwork.shared
                me.working.remove(job.id)
                me.running = false
                if ok { me.failed[job.id] = nil; me.onReady() } else { me.failed[job.id] = Date() }
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
                me.pump()
            }
        }
    }

    // MARK: Objet système (créé hors du MainActor : iOS appelle ces blocs depuis un autre fil)

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    nonisolated private static func makeArtwork(id: String, preview: UIImage?, clip: URL) -> MPMediaItemAnimatedArtwork {
        MPMediaItemAnimatedArtwork(artworkID: id,
                                   previewImageRequestHandler: { _, completion in completion(preview) },
                                   videoAssetFileURLRequestHandler: { _, completion in completion(clip) })
    }
    #endif

    // MARK: Vidéo → clip recadré, sans le son

    private struct ClipError: Error {}

    nonisolated private static func cropVideo(_ source: URL, to out: URL, size: CGSize) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ClipError() }
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        // 20 secondes au plus : le clip tourne en boucle (et se prépare plus vite).
        let length = CMTimeMinimum(duration, CMTime(seconds: 20, preferredTimescale: 600))

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ClipError() }
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: .zero)
        videoTrack.preferredTransform = transform

        let video = try await AVMutableVideoComposition.videoComposition(with: composition) { request in
            request.finish(with: LockScreenArtwork.fill(request.sourceImage, into: size), context: nil)
        }
        video.renderSize = size

        // Certaines vidéos (HDR, 10 bits, formats rares) refusent un réglage : on essaie les suivants.
        let presets = [AVAssetExportPresetHighestQuality, AVAssetExportPreset1920x1080, AVAssetExportPresetMediumQuality]
        var lastError: Error = ClipError()
        for preset in presets {
            guard let export = AVAssetExportSession(asset: composition, presetName: preset) else { continue }
            export.videoComposition = video
            try? FileManager.default.removeItem(at: out)
            do {
                if #available(iOS 18.0, *) {
                    try await export.export(to: out, as: .mp4)
                    return
                } else {
                    throw ClipError()
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Remplit le cadre en recadrant au centre (comme « scaledToFill »).
    nonisolated static func fill(_ image: CIImage, into size: CGSize) -> CIImage {
        let e = image.extent
        let scale = max(size.width / e.width, size.height / e.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let s = scaled.extent
        let dx = s.origin.x + (s.width - size.width) / 2
        let dy = s.origin.y + (s.height - size.height) / 2
        return scaled.transformed(by: CGAffineTransform(translationX: -dx, y: -dy))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    // MARK: GIF → clip vidéo

    nonisolated private static func encodeGIF(_ source: URL, to out: URL, size: CGSize) async throws {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { throw ClipError() }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { throw ClipError() }
        let delays: [Double] = (0..<count).map { i in
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            return d < 0.02 ? 0.1 : d
        }

        let w = Int(size.width), h = Int(size.height)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h
        ])
        guard writer.canAdd(input) else { throw ClipError() }
        writer.add(input)
        guard writer.startWriting() else { throw ClipError() }
        writer.startSession(atSourceTime: .zero)

        var time = 0.0
        var loops = 0
        // Les GIF très courts sont répétés pour faire un clip d'au moins 4 secondes.
        repeat {
            for i in 0..<count {
                guard let frame = CGImageSourceCreateImageAtIndex(src, i, nil),
                      let buffer = Self.makeBuffer(frame, pool: adaptor.pixelBufferPool, width: w, height: h) else { continue }
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                _ = adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600))
                time += delays[i]
            }
            loops += 1
        } while time < 4 && loops < 40

        writer.endSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw ClipError() }
    }

    nonisolated private static func makeBuffer(_ image: CGImage, pool: CVPixelBufferPool?, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, nil, &buffer)
        }
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let scale = max(CGFloat(width) / iw, CGFloat(height) / ih)
        let dw = iw * scale, dh = ih * scale
        ctx.draw(image, in: CGRect(x: (CGFloat(width) - dw) / 2, y: (CGFloat(height) - dh) / 2, width: dw, height: dh))
        return buffer
    }
}

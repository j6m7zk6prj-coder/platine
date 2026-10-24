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
                prepare(id: id, source: source, kind: kind, shape: shape, clip: clip)
            }
        }
        return result
        #else
        return [:]
        #endif
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

    private func prepare(id: String, source: URL, kind: ArtworkKind, shape: Shape, clip: URL) {
        guard !working.contains(id) else { return }
        if let when = failed[id], Date().timeIntervalSince(when) < 90 { return }
        working.insert(id)
        let size = shape.size
        Task.detached(priority: .utility) {
            let temp = clip.deletingLastPathComponent().appendingPathComponent(id + "-tmp.mp4")
            try? FileManager.default.removeItem(at: temp)
            var ok = false
            do {
                if kind == .gif {
                    try await Self.encodeGIF(source, to: temp, size: size)
                } else {
                    try await Self.cropVideo(source, to: temp, size: size)
                }
                try? FileManager.default.removeItem(at: clip)
                try FileManager.default.moveItem(at: temp, to: clip)
                ok = true
            } catch {
                try? FileManager.default.removeItem(at: temp)
            }
            await MainActor.run {
                let me = LockScreenArtwork.shared
                me.working.remove(id)
                if ok { me.failed[id] = nil; me.onReady() } else { me.failed[id] = Date() }
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
        // 30 secondes au plus : le clip tourne en boucle.
        let length = CMTimeMinimum(duration, CMTime(seconds: 30, preferredTimescale: 600))

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

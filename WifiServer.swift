import Foundation
import Network

// MARK: - Le petit serveur web de l'envoi par Wi‑Fi (sans dépendance à l'interface : testé à part sur Mac)

/// Ce que le serveur demande à l'app. Toutes les fonctions peuvent être appelées depuis n'importe quel fil.
struct WifiHandlers: Sendable {
    /// La page servie au navigateur.
    var page: @Sendable () -> Data
    /// Le dossier où déposer la musique reçue (le dossier Platine, importé ensuite par la bibliothèque).
    var inbox: URL
    var began: @Sendable (String) -> Void = { _ in }
    var finished: @Sendable (String) -> Void = { _ in }
    var failed: @Sendable (String) -> Void = { _ in }
    var state: @Sendable (NWListener.State) -> Void = { _ in }
    var library: @Sendable () async -> Data = { Data(#"{"albums":[]}"#.utf8) }
    /// Où en sont les morceaux envoyés (import, album trouvé, paroles).
    var recent: @Sendable () async -> Data = { Data("{}".utf8) }
    var cover: @Sendable (_ album: String?, _ track: String?, _ size: Int) async -> Data? = { _, _, _ in nil }
    /// Pose une pochette : fichier reçu, album ou sons visés, extension, type (image, gif, video).
    var artwork: @Sendable (_ file: URL, _ album: String?, _ tracks: [UUID], _ ext: String, _ kind: String) async -> Bool = { _, _, _, _, _ in false }
}

final class WifiServer: @unchecked Sendable {
    private var listener: NWListener?
    private let lock = NSLock()

    var isRunning: Bool { lock.withLock { listener != nil } }

    func start(port: UInt16, handlers: WifiHandlers) throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { conn in
            HTTPConnection(conn: conn, handlers: handlers).start()
        }
        l.stateUpdateHandler = { handlers.state($0) }
        l.start(queue: DispatchQueue(label: "platine.wifi.listener"))
        lock.withLock { listener = l }
    }

    func stop() {
        let l = lock.withLock { () -> NWListener? in
            let l = listener
            listener = nil
            return l
        }
        l?.cancel()
    }

    /// Les extensions de musique acceptées.
    static let audio: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "alac", "m4b"]
}

/// Une connexion HTTP. Tout se passe sur sa propre file série : jamais deux traitements en même temps.
private final class HTTPConnection: @unchecked Sendable {
    private let conn: NWConnection
    private let handlers: WifiHandlers
    private let queue: DispatchQueue
    private var buffer = Data()
    private var file: FileHandle?
    private var partURL: URL?
    private var remaining = 0
    private var onComplete: ((URL) -> Void)?
    /// Garde la connexion en vie tant qu'elle travaille.
    private var keepAlive: HTTPConnection?

    init(conn: NWConnection, handlers: WifiHandlers) {
        self.conn = conn
        self.handlers = handlers
        self.queue = DispatchQueue(label: "platine.wifi.conn")
    }

    func start() {
        keepAlive = self
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.cleanup()
            default: break
            }
        }
        conn.start(queue: queue)
        readHeader()
    }

    private func cleanup() {
        try? file?.close()
        file = nil
        if let partURL { try? FileManager.default.removeItem(at: partURL) }
        partURL = nil
        keepAlive = nil
    }

    // MARK: Lecture de la requête

    private func readHeader() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let end = self.buffer.range(of: Data([13, 10, 13, 10])) {
                let head = String(decoding: self.buffer[self.buffer.startIndex..<end.lowerBound], as: UTF8.self)
                let rest = Data(self.buffer[end.upperBound...])
                self.buffer = Data()
                self.handle(head: head, body: rest)
            } else if done || error != nil || self.buffer.count > 512 * 1024 {
                self.conn.cancel()
            } else {
                self.readHeader()
            }
        }
    }

    private func handle(head: String, body: Data) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return reply(400, text: "Requête invalide") }
        let method = parts[0].uppercased()
        let target = String(parts[1])
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let (path, query) = Self.parse(target)
        let length = Int(headers["content-length"] ?? "") ?? 0

        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            reply(200, data: handlers.page(), type: "text/html; charset=utf-8")

        case ("GET", "/api/ping"):
            reply(200, text: #"{"ok":true}"#, type: "application/json")

        case ("GET", "/api/library"):
            let h = handlers
            Task { [self] in
                let d = await h.library()
                queue.async { self.reply(200, data: d, type: "application/json") }
            }

        case ("GET", "/api/recent"):
            let h = handlers
            Task { [self] in
                let d = await h.recent()
                queue.async { self.reply(200, data: d, type: "application/json") }
            }

        case ("GET", "/api/cover"):
            let h = handlers
            let size = Int(query["s"] ?? "") ?? 240
            Task { [self] in
                let d = await h.cover(query["album"], query["track"], size)
                queue.async {
                    if let d { self.reply(200, data: d, type: "image/jpeg") } else { self.reply(404, text: "Pas de pochette") }
                }
            }

        case ("PUT", "/upload"), ("POST", "/upload"):
            guard let name = Self.safeName(query["name"] ?? "") else {
                return discard(body, length: length, code: 415, text: #"{"ok":false,"error":"Format non pris en charge"}"#)
            }
            guard length > 0 else { return reply(411, text: #"{"ok":false,"error":"Fichier vide"}"#, type: "application/json") }
            handlers.began(name)
            let h = handlers
            receiveBody(body, length: length) { [self] part in
                let dest = Self.freeURL(in: h.inbox, name: name)
                do {
                    try FileManager.default.createDirectory(at: h.inbox, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: part, to: dest)
                    partURL = nil
                    let saved = dest.lastPathComponent
                    h.finished(saved)
                    let json = (try? JSONSerialization.data(withJSONObject: ["ok": true, "saved": saved])) ?? Data(#"{"ok":true}"#.utf8)
                    reply(200, data: json, type: "application/json")
                } catch {
                    h.failed("\(name) : \(error.localizedDescription)")
                    reply(500, text: #"{"ok":false,"error":"Enregistrement impossible"}"#, type: "application/json")
                }
            }

        case ("PUT", "/api/artwork"), ("POST", "/api/artwork"):
            let ext = (query["ext"] ?? "jpg").lowercased()
            let kinds = ["jpg": "image", "jpeg": "image", "png": "image", "heic": "image",
                         "gif": "gif", "mp4": "video", "mov": "video", "m4v": "video"]
            guard let kind = kinds[ext] else {
                return discard(body, length: length, code: 415, text: #"{"ok":false,"error":"Format non pris en charge"}"#)
            }
            let album = query["album"].flatMap { $0.isEmpty ? nil : $0 }
            let ids = (query["tracks"] ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            guard album != nil || !ids.isEmpty, length > 0 else {
                return discard(body, length: length, code: 400, text: #"{"ok":false,"error":"Rien à modifier"}"#)
            }
            let h = handlers
            receiveBody(body, length: length) { [self] part in
                Task {
                    let ok = await h.artwork(part, album, ids, ext == "jpeg" ? "jpg" : ext, kind)
                    queue.async {
                        try? FileManager.default.removeItem(at: part)
                        self.partURL = nil
                        self.reply(ok ? 200 : 500, text: ok ? #"{"ok":true}"# : #"{"ok":false,"error":"Pochette refusée"}"#, type: "application/json")
                    }
                }
            }

        default:
            discard(body, length: length, code: 404, text: "Introuvable")
        }
    }

    // MARK: Réception d'un fichier, écrit au fur et à mesure

    private func receiveBody(_ first: Data, length: Int, then done: @escaping (URL) -> Void) {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("wifi-upload", isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let part = staging.appendingPathComponent(UUID().uuidString + ".part")
        guard fm.createFile(atPath: part.path, contents: nil), let h = try? FileHandle(forWritingTo: part) else {
            handlers.failed("Écriture impossible sur l’iPhone")
            return discard(first, length: length, code: 500, text: #"{"ok":false,"error":"Écriture impossible"}"#)
        }
        file = h
        partURL = part
        remaining = length
        onComplete = done
        consume(first)
    }

    private func consume(_ data: Data) {
        if !data.isEmpty, remaining > 0 {
            let chunk = data.prefix(remaining)
            do {
                try file?.write(contentsOf: chunk)
            } catch {
                handlers.failed("Plus de place sur l’iPhone ?")
                conn.cancel()
                return
            }
            remaining -= chunk.count
        }
        if remaining <= 0 {
            try? file?.close()
            file = nil
            let done = onComplete
            onComplete = nil
            if let partURL { done?(partURL) }
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isDone, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.consume(data)
            } else if isDone || error != nil {
                self.conn.cancel()
            } else {
                self.consume(Data())
            }
        }
    }

    /// Lit (et jette) le corps d'une requête refusée avant de répondre : sinon le navigateur voit la connexion coupée.
    private func discard(_ first: Data, length: Int, code: Int, text: String) {
        var left = length - first.count
        func drain() {
            guard left > 0 else {
                reply(code, text: text, type: text.hasPrefix("{") ? "application/json" : "text/plain; charset=utf-8")
                return
            }
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
                guard let self else { return }
                left -= data?.count ?? 0
                if (data?.isEmpty ?? true) && (done || error != nil) { self.conn.cancel(); return }
                drain()
            }
        }
        drain()
    }

    // MARK: Réponse

    private func reply(_ code: Int, text: String, type: String = "text/plain; charset=utf-8") {
        reply(code, data: Data(text.utf8), type: type)
    }

    private func reply(_ code: Int, data: Data, type: String) {
        let status = [200: "OK", 400: "Bad Request", 404: "Not Found", 411: "Length Required",
                      415: "Unsupported Media Type", 500: "Internal Server Error"][code] ?? "OK"
        var head = "HTTP/1.1 \(code) \(status)\r\n"
        head += "Content-Type: \(type)\r\nContent-Length: \(data.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        // Envoi puis fermeture propre (la réponse arrive entière avant la fin de la connexion).
        conn.send(content: Data(head.utf8) + data, contentContext: .finalMessage, isComplete: true,
                  completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + 2) { self.conn.cancel() }
        })
    }

    // MARK: Outils

    static func parse(_ target: String) -> (String, [String: String]) {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(pieces.first ?? "/")
        var query: [String: String] = [:]
        if pieces.count > 1 {
            for pair in pieces[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = decode(String(kv[0]))
                let value = kv.count > 1 ? decode(String(kv[1])) : ""
                if query[key] == nil { query[key] = value }
            }
        }
        return (path.removingPercentEncoding ?? path, query)
    }

    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }

    /// Garde seulement le nom du fichier, et seulement la musique et les paroles.
    static func safeName(_ raw: String) -> String? {
        let base = (raw.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !base.hasPrefix(".") else { return nil }
        let ext = (base as NSString).pathExtension.lowercased()
        guard WifiServer.audio.contains(ext) || ext == "lrc" else { return nil }
        return String(base.prefix(200))
    }

    /// Un nom libre dans le dossier (« titre (2).flac » si le nom existe déjà).
    static func freeURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(stem) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}

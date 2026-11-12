import Foundation
import Network

// Test du serveur de l'envoi par Wi‑Fi, sur Mac (lancé par GitHub Actions).
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("wifitest-\(UUID().uuidString)")
let inbox = root.appendingPathComponent("inbox")
try fm.createDirectory(at: inbox, withIntermediateDirectories: true)

let ready = DispatchSemaphore(value: 0)
let server = WifiServer()
try server.start(port: 8091, handlers: WifiHandlers(
    page: { Data("<html>Platine</html>".utf8) },
    inbox: inbox,
    state: { if case .ready = $0 { ready.signal() } },
    library: { Data(#"{"albums":[{"id":"a"}]}"#.utf8) },
    cover: { _, _, _ in Data([0xFF, 0xD8, 0xFF]) },
    artwork: { url, album, _, ext, kind in
        let n = (try? Data(contentsOf: url))?.count ?? 0
        return n == 300_000 && album == "Werenoi|C63" && ext == "jpg" && kind == "image"
    }))
_ = ready.wait(timeout: .now() + 5)

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "OK   " : "ÉCHEC", what)
    if !ok { failures += 1 }
}

func blob(_ size: Int, seed: UInt8) -> Data {
    var d = Data(count: size)
    d.withUnsafeMutableBytes { raw in
        let p = raw.bindMemory(to: UInt8.self)
        for i in 0..<size { p[i] = UInt8(truncatingIfNeeded: i &* 31) &+ seed }
    }
    return d
}

let session = URLSession(configuration: .ephemeral)
func call(_ method: String, _ path: String, body: Data? = nil) async -> (Int, Data) {
    var r = URLRequest(url: URL(string: "http://127.0.0.1:8091" + path)!)
    r.httpMethod = method
    r.timeoutInterval = 60
    do {
        if let body {
            let (d, resp) = try await session.upload(for: r, from: body)
            return ((resp as? HTTPURLResponse)?.statusCode ?? -1, d)
        }
        let (d, resp) = try await session.data(for: r)
        return ((resp as? HTTPURLResponse)?.statusCode ?? -1, d)
    } catch {
        print("   erreur réseau :", error.localizedDescription)
        return (-1, Data())
    }
}

let (c1, d1) = await call("GET", "/")
check(c1 == 200 && String(decoding: d1, as: UTF8.self).contains("Platine"), "page")
check(await call("GET", "/api/ping").0 == 200, "ping")
check(await call("GET", "/api/library").0 == 200, "bibliothèque")
check(await call("GET", "/api/cover?album=a&s=200").0 == 200, "pochette")

let big = blob(28_000_000, seed: 3)
let (c2, _) = await call("PUT", "/upload?name=Werenoi%20-%20C63.flac", body: big)
let saved = inbox.appendingPathComponent("Werenoi - C63.flac")
check(c2 == 200, "envoi d'un FLAC de 28 Mo (code \(c2))")
check((try? Data(contentsOf: saved)) == big, "fichier reçu identique")

// Deux envois en même temps, même nom.
let small = blob(9_000_000, seed: 9)
async let a = call("PUT", "/upload?name=Son.mp3", body: small)
async let b = call("PUT", "/upload?name=Son.mp3", body: small)
let (ra, rb) = await (a, b)
check(ra.0 == 200 && rb.0 == 200, "deux envois en parallèle")
check(fm.fileExists(atPath: inbox.appendingPathComponent("Son.mp3").path)
      && fm.fileExists(atPath: inbox.appendingPathComponent("Son (2).mp3").path), "noms sans doublon")

check(await call("PUT", "/upload?name=photo.exe", body: blob(1_000_000, seed: 1)).0 == 415, "format refusé proprement")
check(await call("PUT", "/api/artwork?ext=jpg&album=Werenoi%7CC63", body: blob(300_000, seed: 4)).0 == 200, "pochette envoyée")
check(await call("GET", "/inconnu").0 == 404, "page inconnue")

// Encore après tout ça : le serveur répond toujours.
check(await call("GET", "/api/ping").0 == 200, "toujours en marche")

server.stop()
try? fm.removeItem(at: root)
print(failures == 0 ? "\nTOUT EST BON" : "\n\(failures) ÉCHEC(S)")
exit(failures == 0 ? 0 : 1)

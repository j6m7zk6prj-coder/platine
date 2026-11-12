import SwiftUI
import Network
import UIKit

// MARK: - Envoi par Wi‑Fi : depuis le navigateur du PC, sans câble ni compte

/// Petit serveur web local. Tant que l'écran « Envoi par Wi‑Fi » est ouvert,
/// le PC (sur le même Wi‑Fi) ouvre l'adresse affichée et y glisse ses musiques.
/// Les fichiers arrivent dans le dossier Platine, puis sont importés comme d'habitude.
@MainActor
@Observable
final class WifiTransfer {
    static let port: UInt16 = 8080

    private(set) var running = false
    private(set) var address: String?
    private(set) var received = 0
    private(set) var currentFile: String?
    private(set) var failed: String?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanAgain = false
    @ObservationIgnored private weak var library: Library?

    func start(library: Library) {
        guard listener == nil else { return }
        self.library = library
        failed = nil
        received = 0
        address = Self.wifiAddress().map { "http://\($0):\(Self.port)" }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            let events = UploadEvents(owner: self)
            l.newConnectionHandler = Self.connectionHandler(events)
            l.stateUpdateHandler = Self.stateHandler(events)
            l.start(queue: .global(qos: .userInitiated))
            listener = l
        } catch {
            failed = "Le serveur n’a pas pu démarrer."
        }
    }

    nonisolated private static func connectionHandler(_ events: UploadEvents) -> (NWConnection) -> Void {
        { conn in UploadConnection(conn: conn, events: events).start() }
    }

    nonisolated private static func stateHandler(_ events: UploadEvents) -> (NWListener.State) -> Void {
        { state in events.state(state) }
    }

    fileprivate func listenerState(_ state: NWListener.State) {
        switch state {
        case .ready: running = true
        case .failed(let e):
            running = false
            failed = "Le serveur n’a pas pu démarrer (\(e.localizedDescription))."
        case .cancelled: running = false
        default: break
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
        currentFile = nil
    }

    fileprivate func began(_ name: String) { currentFile = name }

    fileprivate func finished(_ name: String) {
        received += 1
        if currentFile == name { currentFile = nil }
        requestScan()
    }

    /// Importe les fichiers reçus (un seul import à la fois ; on relance si d'autres arrivent pendant ce temps).
    private func requestScan() {
        scanAgain = true
        guard scanTask == nil else { return }
        scanTask = Task { [weak self] in
            while let self, self.scanAgain {
                self.scanAgain = false
                try? await Task.sleep(for: .milliseconds(800))
                await self.library?.scanInbox()
            }
            self?.scanTask = nil
        }
    }

    /// L'adresse IPv4 de l'iPhone sur le Wi‑Fi.
    nonisolated static func wifiAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = ptr.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(i.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let name = String(cString: i.ifa_name)
            if name == "en0" { return ip }
            if fallback == nil, name.hasPrefix("en") || name.hasPrefix("bridge") { fallback = ip }
        }
        return fallback
    }
}

/// Relaie les évènements d'une connexion vers l'écran (sur le fil principal).
private struct UploadEvents: @unchecked Sendable {
    weak var owner: WifiTransfer?
    func began(_ n: String) { Task { @MainActor in owner?.began(n) } }
    func finished(_ n: String) { Task { @MainActor in owner?.finished(n) } }
    func state(_ s: NWListener.State) { Task { @MainActor in owner?.listenerState(s) } }
}

/// Une connexion HTTP : sert la page, ou reçoit un fichier envoyé en PUT (écrit au fur et à mesure).
private final class UploadConnection: @unchecked Sendable {
    private let conn: NWConnection
    private let events: UploadEvents?
    /// Le dossier Platine (Documents), surveillé par la bibliothèque.
    private static let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private static let audio: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "alac", "m4b"]
    private var header = Data()
    private var file: FileHandle?
    private var partURL: URL?
    private var finalURL: URL?
    private var remaining = 0
    private var name = ""

    init(conn: NWConnection, events: UploadEvents) {
        self.conn = conn
        self.events = events
    }

    func start() {
        conn.start(queue: .global(qos: .userInitiated))
        readHeader()
    }

    private func readHeader() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, done, error in
            if let data { header.append(data) }
            if let end = header.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: header[..<end.lowerBound], as: UTF8.self)
                let rest = header[end.upperBound...]
                handle(head: head, body: Data(rest))
            } else if done || error != nil || header.count > 64 * 1024 {
                conn.cancel()
            } else {
                readHeader()
            }
        }
    }

    private func handle(head: String, body: Data) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return reply(400, "Requête invalide") }
        let method = String(parts[0])
        let target = String(parts[1])
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let c = l.firstIndex(of: ":") {
                headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let comps = URLComponents(string: target)
        let path = comps?.path ?? "/"

        if method == "GET", path == "/" {
            return reply(200, WifiPage.html, type: "text/html; charset=utf-8")
        }
        if method == "PUT" || method == "POST", path == "/upload" {
            let raw = comps?.queryItems?.first { $0.name == "name" }?.value ?? ""
            guard let clean = Self.safeName(raw) else {
                return reply(415, "{\"ok\":false,\"error\":\"Format non pris en charge\"}", type: "application/json")
            }
            remaining = Int(headers["content-length"] ?? "") ?? -1
            guard remaining >= 0 else { return reply(411, "Taille manquante") }
            name = clean
            let fm = FileManager.default
            let staging = fm.temporaryDirectory.appendingPathComponent("wifi-upload", isDirectory: true)
            try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let part = staging.appendingPathComponent(UUID().uuidString + ".part")
            fm.createFile(atPath: part.path, contents: nil)
            guard let h = try? FileHandle(forWritingTo: part) else { return reply(500, "Écriture impossible") }
            file = h
            partURL = part
            finalURL = Self.freeURL(in: Self.inbox, name: clean)
            events?.began(clean)
            write(body)
            return
        }
        reply(404, "Introuvable")
    }

    private func write(_ data: Data) {
        if !data.isEmpty {
            let chunk = data.prefix(max(0, remaining))
            file?.write(chunk)
            remaining -= chunk.count
        }
        if remaining <= 0 { return complete() }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, done, error in
            if let data, !data.isEmpty {
                write(data)
            } else if done || error != nil {
                abort()
            } else {
                write(Data())
            }
        }
    }

    private func complete() {
        try? file?.close()
        file = nil
        guard let part = partURL, let dest = finalURL else { return reply(500, "Erreur") }
        do {
            try FileManager.default.moveItem(at: part, to: dest)
            events?.finished(name)
            reply(200, "{\"ok\":true}", type: "application/json")
        } catch {
            try? FileManager.default.removeItem(at: part)
            reply(500, "{\"ok\":false}", type: "application/json")
        }
    }

    private func abort() {
        try? file?.close()
        file = nil
        if let partURL { try? FileManager.default.removeItem(at: partURL) }
        conn.cancel()
    }

    private func reply(_ code: Int, _ body: String, type: String = "text/plain; charset=utf-8") {
        let status = [200: "OK", 400: "Bad Request", 404: "Not Found", 411: "Length Required",
                      415: "Unsupported Media Type", 500: "Internal Server Error"][code] ?? "OK"
        let data = Data(body.utf8)
        var head = "HTTP/1.1 \(code) \(status)\r\n"
        head += "Content-Type: \(type)\r\nContent-Length: \(data.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + data, completion: .contentProcessed { [conn] _ in conn.cancel() })
    }

    /// Garde seulement le nom du fichier, et seulement la musique et les paroles.
    static func safeName(_ raw: String) -> String? {
        let base = (raw as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !base.hasPrefix(".") else { return nil }
        let ext = (base as NSString).pathExtension.lowercased()
        guard audio.contains(ext) || ext == "lrc" else { return nil }
        return String(base.prefix(200))
    }

    /// Un nom libre dans le dossier (« titre (2).mp3 » si le nom existe déjà).
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

// MARK: - L'écran dans l'app

struct WifiTransferView: View {
    @Environment(Library.self) private var library
    @State private var transfer = WifiTransfer()
    @State private var startCount = 0

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    Image(systemName: transfer.running ? "wifi" : "wifi.slash")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(transfer.running ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                        .symbolEffect(.variableColor.iterative, isActive: transfer.running && transfer.currentFile != nil)
                    if let address = transfer.address {
                        Text("Sur ton PC, ouvre cette adresse :")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(address)
                            .font(.system(.title2, design: .monospaced).weight(.bold))
                            .textSelection(.enabled)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    } else {
                        Text("Connecte l’iPhone au Wi‑Fi")
                            .font(.headline)
                        Text("L’iPhone et le PC doivent être sur le même réseau Wi‑Fi.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }

            Section("En direct") {
                LabeledContent("Fichiers reçus", value: "\(transfer.received)")
                LabeledContent("Morceaux ajoutés", value: "\(max(0, library.tracks.count - startCount))")
                if let f = transfer.currentFile {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(f).lineLimit(1).foregroundStyle(.secondary)
                    }
                } else if library.isImporting {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Import en cours…").foregroundStyle(.secondary)
                    }
                }
                if let failed = transfer.failed {
                    Text(failed).foregroundStyle(.red)
                }
            }

            Section {
                Label("Ouvre l’adresse dans Chrome, Edge ou Safari sur ton PC.", systemImage: "1.circle")
                Label("Glisse tes musiques (ou un dossier entier) dans la page.", systemImage: "2.circle")
                Label("Garde cet écran ouvert jusqu’à la fin de l’envoi.", systemImage: "3.circle")
            } header: {
                Text("Comment faire")
            } footer: {
                Text("Si iOS demande l’accès au réseau local, accepte : sans ça, le PC ne peut pas joindre l’iPhone. Les paroles .lrc sont acceptées aussi, avec le même nom que le morceau.")
            }
        }
        .navigationTitle("Envoi par Wi‑Fi")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            startCount = library.tracks.count
            transfer.start(library: library)
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            transfer.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

// MARK: - La page web servie au PC

enum WifiPage {
    static let html = #"""
<!doctype html><html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Platine · Envoi par Wi‑Fi</title>
<style>
:root{color-scheme:dark;--bg:#0b0b12;--card:#16161f;--line:#2a2a38;--text:#f4f4f8;--muted:#9a9aae;--accent:#fa2d48;--ok:#30d158}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(1200px 600px at 20% -10%,#3a1450 0,transparent 60%),radial-gradient(900px 500px at 100% 110%,#0a3a6a 0,transparent 60%),var(--bg);color:var(--text);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;min-height:100vh}
main{max-width:760px;margin:0 auto;padding:48px 20px}
h1{font-size:30px;margin:0 0 4px;letter-spacing:-.02em}p.sub{color:var(--muted);margin:0 0 28px}
#drop{border:2px dashed var(--line);border-radius:24px;padding:56px 20px;text-align:center;background:rgba(255,255,255,.04);backdrop-filter:blur(20px);transition:.2s;cursor:pointer}
#drop.over{border-color:var(--accent);background:rgba(250,45,72,.08);transform:scale(1.01)}
#drop b{display:block;font-size:20px;margin-bottom:6px}#drop span{color:var(--muted)}
.btn{display:inline-block;margin-top:18px;padding:10px 20px;border-radius:999px;background:var(--accent);color:#fff;font-weight:600;border:0;cursor:pointer;font-size:15px}
#sum{margin:26px 0 10px;color:var(--muted);display:flex;justify-content:space-between;gap:12px}
#bar{height:6px;border-radius:9px;background:var(--line);overflow:hidden;margin-bottom:16px}#bar i{display:block;height:100%;width:0;background:var(--accent);transition:width .2s}
ul{list-style:none;margin:0;padding:0}li{display:flex;align-items:center;gap:12px;padding:10px 14px;border-radius:14px;background:var(--card);margin-bottom:6px}
li .n{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}li .s{color:var(--muted);font-variant-numeric:tabular-nums;min-width:64px;text-align:right}
li.ok .s{color:var(--ok)}li.err .s{color:var(--accent)}
</style></head><body><main>
<h1>Platine</h1><p class="sub">Glisse tes musiques ici : elles arrivent directement dans ta bibliothèque sur l’iPhone.</p>
<div id="drop"><b>Dépose tes musiques ou un dossier</b><span>MP3, M4A, FLAC, WAV, AIFF… et paroles .lrc</span><br>
<button class="btn" id="pick">Choisir des fichiers</button><input id="file" type="file" multiple hidden accept="audio/*,.lrc,.flac,.m4a,.aiff,.aif,.alac,.caf,.m4b"></div>
<div id="sum"><span id="count">Aucun envoi</span><span id="size"></span></div><div id="bar"><i></i></div><ul id="list"></ul>
</main><script>
const ok=/\.(mp3|m4a|aac|wav|aif|aiff|caf|flac|alac|m4b|lrc)$/i;const q=[];let active=0,done=0,total=0,bytesDone=0,bytesTotal=0;
const $=s=>document.querySelector(s),list=$('#list');
const fmt=b=>b>1e9?(b/1e9).toFixed(2)+' Go':(b/1e6).toFixed(1)+' Mo';
function upd(){$('#count').textContent=total?`${done} / ${total} envoyés`:'Aucun envoi';$('#size').textContent=bytesTotal?`${fmt(bytesDone)} / ${fmt(bytesTotal)}`:'';$('#bar i').style.width=bytesTotal?(100*bytesDone/bytesTotal)+'%':'0'}
function add(f){if(!ok.test(f.name))return;const li=document.createElement('li');li.innerHTML='<span class="n"></span><span class="s">En attente</span>';li.querySelector('.n').textContent=f.name;list.appendChild(li);q.push({f,li,sent:0});total++;bytesTotal+=f.size;upd();next()}
function next(){while(active<2&&q.length){send(q.shift())}}
function send(it){active++;const x=new XMLHttpRequest();x.open('PUT','/upload?name='+encodeURIComponent(it.f.name));const s=it.li.querySelector('.s');
x.upload.onprogress=e=>{bytesDone+=e.loaded-it.sent;it.sent=e.loaded;s.textContent=Math.round(100*e.loaded/(e.total||1))+' %';upd()};
x.onload=()=>{active--;done++;bytesDone+=it.f.size-it.sent;it.sent=it.f.size;if(x.status==200){it.li.className='ok';s.textContent='✓'}else{it.li.className='err';s.textContent=x.status==415?'Format refusé':'Erreur'}upd();next()};
x.onerror=()=>{active--;done++;it.li.className='err';s.textContent='Coupé';upd();next()};x.send(it.f)}
function walk(e){if(e.isFile)e.file(add);else if(e.isDirectory){const r=e.createReader();const rd=()=>r.readEntries(es=>{if(es.length){es.forEach(walk);rd()}});rd()}}
const d=$('#drop');['dragenter','dragover'].forEach(t=>d.addEventListener(t,e=>{e.preventDefault();d.classList.add('over')}));
['dragleave','drop'].forEach(t=>d.addEventListener(t,e=>{e.preventDefault();d.classList.remove('over')}));
d.addEventListener('drop',e=>{const its=[...e.dataTransfer.items];if(its.length&&its[0].webkitGetAsEntry){its.forEach(i=>{const en=i.webkitGetAsEntry();if(en)walk(en)})}else[...e.dataTransfer.files].forEach(add)});
$('#pick').onclick=e=>{e.stopPropagation();$('#file').click()};d.onclick=()=>$('#file').click();$('#file').onchange=e=>{[...e.target.files].forEach(add);e.target.value=''};
window.addEventListener('beforeunload',e=>{if(active||q.length){e.preventDefault();e.returnValue=''}});
</script></body></html>
"""#
}

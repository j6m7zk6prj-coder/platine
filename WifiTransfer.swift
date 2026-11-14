import SwiftUI
import Network
import UIKit

// MARK: - Envoi par Wi‑Fi : depuis le navigateur du PC, sans câble ni compte

/// Le serveur de l'envoi par Wi‑Fi, côté app. Il reste allumé tant que Platine est ouverte
/// (même si tu quittes l'écran), et se rallume tout seul quand tu reviens dans l'app.
@MainActor
@Observable
final class WifiTransfer {
    static let shared = WifiTransfer()
    static let port: UInt16 = 8080

    private(set) var enabled = false
    private(set) var running = false
    private(set) var address: String?
    private(set) var received = 0
    private(set) var artworks = 0
    private(set) var currentFile: String?
    private(set) var failed: String?

    @ObservationIgnored private let server = WifiServer()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanAgain = false
    @ObservationIgnored private weak var library: Library?
    @ObservationIgnored private var albumIndex: [String: AlbumInfo] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Suivi de chaque fichier envoyé, affiché sur la page du PC.
    struct Status: Encodable {
        var state: String
        var album: String?
        var lyrics: String?
        var id: String?
        var title: String?
        var artist: String?
        var cover: Bool?
    }
    @ObservationIgnored private var recent: [String: Status] = [:]

    private init() {
        let c = NotificationCenter.default
        observers.append(c.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wentToBackground() }
        })
        observers.append(c.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        })
    }

    func enable(library: Library) {
        self.library = library

        enabled = true
        UIApplication.shared.isIdleTimerDisabled = true
        launch()
    }

    func disable() {
        enabled = false
        server.stop()
        running = false
        currentFile = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func launch() {
        failed = nil
        address = Self.wifiAddress().map { "http://\($0):\(Self.port)" }
        guard !server.isRunning else { return }
        do {
            try server.start(port: Self.port, handlers: makeHandlers())
        } catch {
            failed = "Le serveur n’a pas pu démarrer."
        }
    }

    /// En quittant l'app, iOS laisse encore un peu de temps : les envois en cours peuvent finir.
    private func wentToBackground() {
        guard enabled else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Envoi Wi‑Fi") { [weak self] in
            MainActor.assumeIsolated { self?.endBackground() }
        }
    }

    private func endBackground() {
        server.stop()
        running = false
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func cameBack() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        guard enabled else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        launch()
    }

    private func makeHandlers() -> WifiHandlers {
        let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return WifiHandlers(
            page: { Data(WifiPage.html.utf8) },
            inbox: inbox,
            began: { n in Task { @MainActor in WifiTransfer.shared.currentFile = n } },
            finished: { n in Task { @MainActor in WifiTransfer.shared.finished(n) } },
            failed: { m in Task { @MainActor in WifiTransfer.shared.failed = m } },
            state: { st in Task { @MainActor in WifiTransfer.shared.listenerState(st) } },
            library: { await MainActor.run { WifiTransfer.shared.libraryJSON() } },
            recent: { await MainActor.run { WifiTransfer.shared.recentJSON() } },
            cover: { album, track, size in await MainActor.run { WifiTransfer.shared.coverJPEG(album: album, track: track, size: size) } },
            artwork: { file, album, tracks, ext, kind in
                await MainActor.run { WifiTransfer.shared.applyArtwork(file: file, album: album, tracks: tracks, ext: ext, kind: kind) }
            })
    }

    private func listenerState(_ state: NWListener.State) {
        switch state {
        case .ready: running = true
        case .failed(let e):
            running = false
            failed = "Le serveur n’a pas pu démarrer (\(e.localizedDescription))."
        case .cancelled: running = false
        default: break
        }
    }

    private func finished(_ name: String) {
        received += 1
        currentFile = nil
        let isLyrics = (name as NSString).pathExtension.lowercased() == "lrc"
        recent[name] = Status(state: isLyrics ? "ok" : "attente", album: nil, lyrics: isLyrics ? "fichier" : nil)
        requestScan()
    }

    /// Après l'import : les fichiers envoyés passent en « recherche » (ou « illisible »).
    func imported(_ added: [(file: String, id: UUID)], all: [String]) {
        let ok = Set(added.map(\.file))
        for name in all where recent[name] != nil {
            recent[name]?.state = ok.contains(name) ? "recherche" : "illisible"
        }
    }

    /// Album, pochette et paroles trouvés pour un fichier envoyé : affiché sur la page du PC.
    func enriched(_ file: String, _ r: TrackEnricher.Result) {
        guard recent[file] != nil else { return }
        recent[file] = Status(state: "ok", album: r.album, lyrics: r.lyrics,
                              id: r.id, title: r.title, artist: r.artist, cover: r.cover)
    }

    private func recentJSON() -> Data {
        (try? JSONEncoder().encode(recent)) ?? Data("{}".utf8)
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

    // MARK: Pochettes

    /// La bibliothèque (albums et sons) pour l'éditeur de pochettes du PC.
    private func libraryJSON() -> Data {
        struct T: Encodable { let id: String; let title: String; let artist: String; let n: Int }
        struct A: Encodable { let id: String; let title: String; let artist: String; let year: Int; let animated: Bool; let tracks: [T] }
        struct Root: Encodable { let albums: [A] }
        guard let library else { return Data(#"{"albums":[]}"#.utf8) }
        let albums = library.albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        albumIndex = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let list = albums.map { a in
            A(id: a.id, title: a.title, artist: a.artist, year: a.year, animated: library.motion(a.cover) != nil,
              tracks: a.tracks.map { T(id: $0.id.uuidString, title: $0.title, artist: $0.displayArtist, n: $0.trackNumber) })
        }
        return (try? JSONEncoder().encode(Root(albums: list))) ?? Data(#"{"albums":[]}"#.utf8)
    }

    /// Une vignette JPEG de la pochette d'un album ou d'un son.
    private func coverJPEG(album: String?, track: String?, size: Int) -> Data? {
        guard let library else { return nil }
        var t: Track?
        if let album { t = (albumIndex[album] ?? library.albums.first { $0.id == album })?.cover }
        if t == nil, let track, let id = UUID(uuidString: track) { t = library.track(id) }
        guard let t, let image = library.image(for: t) else { return nil }
        let side = CGFloat(min(max(size, 60), 1000))
        let small = image.preparingThumbnail(of: CGSize(width: side, height: side)) ?? image
        return small.jpegData(compressionQuality: 0.82)
    }

    /// Pose la pochette reçue : sur tout l'album, ou sur les sons choisis.
    private func applyArtwork(file: URL, album: String?, tracks: [UUID], ext: String, kind: String) -> Bool {
        guard let library, let data = try? Data(contentsOf: file), !data.isEmpty,
              let k = ArtworkKind(rawValue: kind) else { return false }
        if let album, !album.isEmpty {
            library.setAlbumCover(album, data: data, ext: ext, kind: k)
        } else {
            let ids = Set(tracks.filter { library.track($0) != nil })
            guard !ids.isEmpty else { return false }
            library.setCustomArtwork(ids, data: data, ext: ext, kind: k)
        }
        artworks += 1
        return true
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

// MARK: - L'écran dans l'app

struct WifiTransferView: View {
    @Environment(Library.self) private var library
    @State private var startCount = 0
    private var transfer: WifiTransfer { WifiTransfer.shared }

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    Image(systemName: transfer.running ? "wifi" : "wifi.slash")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(transfer.running ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                        .symbolEffect(.variableColor.iterative, isActive: transfer.running && transfer.currentFile != nil)
                    if !transfer.enabled {
                        Text("Envoi arrêté").font(.headline)
                    } else if let address = transfer.address {
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
                    Button(transfer.enabled ? "Arrêter l’envoi" : "Relancer l’envoi") {
                        transfer.enabled ? transfer.disable() : transfer.enable(library: library)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }

            Section("En direct") {
                LabeledContent("Fichiers reçus", value: "\(transfer.received)")
                LabeledContent("Morceaux ajoutés", value: "\(max(0, library.tracks.count - startCount))")
                LabeledContent("Pochettes posées", value: "\(transfer.artworks)")
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
                Label("Onglet Musique : glisse tes musiques (ou un dossier entier).", systemImage: "2.circle")
                Label("Onglet Pochettes : choisis un album, dépose une image, un GIF ou une vidéo, recadre-la puis envoie-la.", systemImage: "3.circle")
                Label("Garde Platine ouverte à l’écran pendant l’envoi (tu peux aller dans la Bibliothèque). L’écran ne se met pas en veille.", systemImage: "iphone")
            } header: {
                Text("Comment faire")
            } footer: {
                Text("Si iOS demande l’accès au réseau local, accepte : sans ça, le PC ne peut pas joindre l’iPhone. Si tu verrouilles l’iPhone ou changes d’app, l’envoi se met en pause et reprend tout seul quand tu reviens dans Platine.")
            }
        }
        .navigationTitle("Envoi par Wi‑Fi")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            startCount = library.tracks.count
            if !transfer.enabled { transfer.enable(library: library) }
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
:root{color-scheme:dark;--bg:#0b0b12;--card:rgba(255,255,255,.05);--card2:rgba(255,255,255,.08);--line:rgba(255,255,255,.12);--text:#f4f4f8;--muted:#9a9aae;--accent:#fa2d48;--ok:#30d158}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(1200px 600px at 20% -10%,#3a1450 0,transparent 60%),radial-gradient(900px 500px at 100% 110%,#0a3a6a 0,transparent 60%),var(--bg) fixed;color:var(--text);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;min-height:100vh}
main{max-width:1180px;margin:0 auto;padding:36px 20px 60px}
header{display:flex;align-items:center;gap:18px;flex-wrap:wrap;margin-bottom:26px}h1{font-size:30px;margin:0;letter-spacing:-.02em;flex:1}
.tabs{display:flex;gap:4px;padding:4px;border-radius:999px;background:var(--card);border:1px solid var(--line)}
.tab{border:0;background:none;color:var(--muted);font:600 14px inherit;font-family:inherit;padding:8px 18px;border-radius:999px;cursor:pointer}.tab.on{background:#fff;color:#000}
.conn{display:flex;align-items:center;gap:8px;font-size:13px;color:var(--muted);padding:6px 12px;border-radius:999px;background:var(--card);border:1px solid var(--line)}.conn i{width:8px;height:8px;border-radius:50%;background:#888}.conn.on i{background:var(--ok);box-shadow:0 0 8px var(--ok)}.conn.off i{background:var(--accent)}.conn.off{color:#fff}
#veil{position:fixed;inset:0;z-index:50;display:none;align-items:center;justify-content:center;background:rgba(10,10,18,.75);backdrop-filter:blur(10px);font-size:26px;font-weight:700;border:3px dashed var(--accent);border-radius:28px;margin:14px}#veil.on{display:flex}
li .th{width:46px;height:46px;border-radius:8px;object-fit:cover;background:var(--card2);flex:none}
.panel{display:none}.panel.on{display:block}p.sub{color:var(--muted);margin:0 0 22px}
.drop{border:2px dashed var(--line);border-radius:24px;padding:48px 20px;text-align:center;background:var(--card);backdrop-filter:blur(20px);transition:.2s;cursor:pointer}
.drop.over{border-color:var(--accent);background:rgba(250,45,72,.08)}.drop b{display:block;font-size:19px;margin-bottom:6px}.drop span{color:var(--muted)}
.btn{display:inline-flex;align-items:center;gap:6px;padding:10px 20px;border-radius:999px;background:var(--accent);color:#fff;font:600 15px inherit;font-family:inherit;border:0;cursor:pointer}
.btn.ghost{background:var(--card2);border:1px solid var(--line)}.btn:disabled{opacity:.4;cursor:default}.mt{margin-top:16px}
#sum{margin:24px 0 10px;color:var(--muted);display:flex;justify-content:space-between;gap:12px}
.bar{height:6px;border-radius:9px;background:var(--line);overflow:hidden;margin-bottom:14px}.bar i{display:block;height:100%;width:0;background:var(--accent);transition:width .2s}
ul{list-style:none;margin:0;padding:0}li{display:flex;align-items:center;gap:12px;padding:10px 14px;border-radius:14px;background:var(--card);margin-bottom:6px}
li .n{flex:1;min-width:0}li .n b{display:block;font-weight:500;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}li .n small{display:block;color:var(--muted);font-size:13px;margin-top:2px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}li .n small.good{color:#b9f3c8}li .n small.bad{color:var(--accent)}
li .go{border:0;background:var(--card2);color:var(--text);border-radius:99px;padding:6px 12px;font:600 13px inherit;font-family:inherit;cursor:pointer;white-space:nowrap}li .s{color:var(--muted);font-variant-numeric:tabular-nums;min-width:70px;text-align:right}li.ok .s{color:var(--ok)}li.err .s{color:var(--accent)}
.art{display:grid;grid-template-columns:1fr 400px;gap:24px;align-items:start}@media(max-width:900px){.art{grid-template-columns:1fr}}
.tools{display:flex;gap:10px;margin-bottom:16px;flex-wrap:wrap}input[type=search]{flex:1;min-width:200px;padding:11px 16px;border-radius:999px;border:1px solid var(--line);background:var(--card);color:var(--text);font:inherit;outline:none}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:16px}
.card{background:none;border:0;color:inherit;text-align:left;padding:0;cursor:pointer;font:inherit}.card .im{position:relative;aspect-ratio:1;border-radius:14px;overflow:hidden;background:var(--card2);box-shadow:0 8px 24px rgba(0,0,0,.35);transition:transform .15s}
.card:hover .im{transform:translateY(-2px)}.card.sel .im{outline:3px solid var(--accent);outline-offset:3px}.card img{width:100%;height:100%;object-fit:cover;display:block}
.card b{display:block;margin-top:8px;font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.card span{display:block;color:var(--muted);font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.badge{position:absolute;top:8px;left:8px;font-size:11px;font-weight:700;padding:3px 8px;border-radius:99px;background:rgba(0,0,0,.55);backdrop-filter:blur(8px)}
.editor{position:sticky;top:20px;padding:20px;border-radius:24px;background:rgba(20,20,30,.6);border:1px solid var(--line);backdrop-filter:blur(30px)}
.editor h2{margin:0;font-size:20px}.editor .who{color:var(--muted);margin-bottom:14px}
.stage{position:relative;aspect-ratio:1;border-radius:18px;overflow:hidden;background:#000;touch-action:none}
.stage canvas,.stage img,.stage video{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}.stage canvas{cursor:grab}.stage canvas:active{cursor:grabbing}
.stage .hint{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:6px;text-align:center;padding:20px;background:rgba(0,0,0,.45);opacity:0;transition:.2s;pointer-events:none}
.stage.empty .hint,.stage.over .hint{opacity:1}.hint b{font-size:16px}.hint span{color:#ddd;font-size:13px}
.ctl{display:grid;grid-template-columns:96px 1fr;gap:8px 12px;align-items:center;margin-top:14px;font-size:13px;color:var(--muted)}input[type=range]{width:100%;accent-color:var(--accent)}
.row{display:flex;gap:8px;flex-wrap:wrap;margin-top:12px}.target{margin-top:16px;padding-top:14px;border-top:1px solid var(--line)}
.target label{display:flex;align-items:center;gap:8px;padding:4px 0;cursor:pointer}.tracks{max-height:180px;overflow:auto;margin:6px 0 0 24px;font-size:14px}
.status{margin-top:12px;color:var(--muted);min-height:20px}.status.ok{color:var(--ok)}.status.err{color:var(--accent)}
.empty-ed{color:var(--muted);text-align:center;padding:40px 10px}
dialog{background:#15151f;color:var(--text);border:1px solid var(--line);border-radius:22px;padding:22px;width:min(720px,94vw)}dialog::backdrop{background:rgba(0,0,0,.6)}
.bl{display:grid;grid-template-columns:56px 1fr 1.2fr 70px;gap:12px;align-items:center;padding:8px 0;border-bottom:1px solid var(--line)}.bl img{width:56px;height:56px;object-fit:cover;border-radius:8px}
.bl select{width:100%;padding:8px;border-radius:10px;background:var(--card2);color:var(--text);border:1px solid var(--line)}.bl .n{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
</style></head><body><main>
<header><h1>Platine</h1><div class="conn" id="conn"><i></i><span>Connexion…</span></div><div class="tabs"><button class="tab on" data-t="music">Musique</button><button class="tab" data-t="art">Pochettes</button></div></header>

<div id="veil">Dépose tes musiques n’importe où</div>
<section class="panel on" id="p-music">
<p class="sub">Glisse tes musiques n’importe où sur la page, comme dans Musique sur PC : l’artiste, l’album, la pochette et les paroles synchronisées sont trouvés tout seuls.</p>
<div class="drop" id="drop"><b>Dépose tes musiques ou un dossier</b><span>MP3, M4A, FLAC, WAV, AIFF… et paroles .lrc</span><br>
<button class="btn mt" id="pick">Choisir des fichiers</button><input id="file" type="file" multiple hidden accept="audio/*,.lrc,.flac,.m4a,.aiff,.aif,.alac,.caf,.m4b"></div>
<div id="sum"><span id="count">Aucun envoi</span><span id="size"></span></div><div class="bar" id="bar"><i></i></div><ul id="list"></ul>
</section>

<section class="panel" id="p-art">
<p class="sub">Choisis un album, dépose une image, un GIF ou une vidéo, ajuste-la, puis envoie-la sur l’iPhone.</p>
<div class="art"><div>
<div class="tools"><input type="search" id="q" placeholder="Rechercher un album, un artiste, un son…"><button class="btn ghost" id="bulkBtn">Plusieurs pochettes d’un coup</button><input id="bulk" type="file" multiple hidden accept="image/*,.gif,video/*"></div>
<div class="grid" id="grid"><div class="empty-ed">Chargement de la bibliothèque…</div></div>
</div>
<aside class="editor" id="ed"><div class="empty-ed">Choisis un album à gauche.</div></aside>
</div>
</section>

<dialog id="dlg"><h2 style="margin:0 0 4px">Plusieurs pochettes</h2><p class="sub" style="margin-bottom:10px">Chaque fichier est associé à l’album dont le nom ressemble le plus. Corrige si besoin.</p>
<div id="bulkList"></div><div class="row" style="justify-content:flex-end;margin-top:16px"><button class="btn ghost" id="bulkCancel">Annuler</button><button class="btn" id="bulkSend">Tout envoyer</button></div></dialog>
</main><script>
const $=s=>document.querySelector(s);
const el=(t,c)=>{const e=document.createElement(t);if(c)e.className=c;return e};
const fmt=b=>b>1e9?(b/1e9).toFixed(2)+' Go':(b/1e6).toFixed(1)+' Mo';
const norm=s=>(s||'').normalize('NFD').replace(/[̀-ͯ]/g,'').toLowerCase().replace(/\(.*?\)|\[.*?\]/g,'').replace(/[^a-z0-9]/g,'');
document.querySelectorAll('.tab').forEach(b=>b.onclick=()=>{document.querySelectorAll('.tab').forEach(x=>x.classList.toggle('on',x==b));document.querySelectorAll('.panel').forEach(p=>p.classList.toggle('on',p.id=='p-'+b.dataset.t));if(b.dataset.t=='art'&&!lib)loadLib()});

/* ---------- Musique ---------- */
const ok=/\.(mp3|m4a|aac|wav|aif|aiff|caf|flac|alac|m4b|lrc)$/i;const q=[];let active=0,done=0,total=0,bytesDone=0,bytesTotal=0;const list=$('#list');
function upd(){$('#count').textContent=total?`${done} / ${total} envoyés`:'Aucun envoi';$('#size').textContent=bytesTotal?`${fmt(bytesDone)} / ${fmt(bytesTotal)}`:'';$('#bar i').style.width=bytesTotal?(100*bytesDone/bytesTotal)+'%':'0'}
function add(f){if(!ok.test(f.name))return;const li=el('li');li.innerHTML='<img class="th" alt=""><div class="n"><b></b><small></small></div><span class="s">En attente</span>';li.querySelector('.th').style.visibility='hidden';li.querySelector('.n b').textContent=f.name;list.appendChild(li);q.push({f,li,sent:0});total++;bytesTotal+=f.size;upd();next()}
function next(){while(active<1&&q.length){send(q.shift())}}
const wait=ms=>new Promise(r=>setTimeout(r,ms));
async function waitPhone(s){for(;;){if(await ping())return;s.textContent='En attente de l’iPhone…';await wait(2000)}}
function send(it){active++;const s=it.li.querySelector('.s');it.tries=(it.tries||0)+1;const x=new XMLHttpRequest();x.open('PUT','/upload?name='+encodeURIComponent(it.f.name));
const back=()=>{bytesDone-=it.sent;it.sent=0;upd()};
x.upload.onprogress=e=>{bytesDone+=e.loaded-it.sent;it.sent=e.loaded;s.textContent=Math.round(100*e.loaded/(e.total||1))+' %';upd()};
x.onload=async()=>{if(x.status==200){active--;done++;bytesDone+=it.f.size-it.sent;it.sent=it.f.size;it.li.className='ok';s.textContent='✓';upd();next();lib=null;
let saved=it.f.name;try{saved=JSON.parse(x.responseText).saved||saved}catch(e){}if(!/\.lrc$/i.test(saved)){track[saved]=it;detail(it,'Import et recherche de l’album et des paroles…');poll()}return}
let msg='Erreur '+x.status;try{msg=JSON.parse(x.responseText).error||msg}catch(e){}
if(x.status>=500&&it.tries<4){back();s.textContent='Nouvel essai…';await wait(1500);active--;send(it);return}
active--;done++;back();it.li.className='err';s.textContent=msg;upd();next()};
x.onerror=async()=>{back();if(it.tries<20){s.textContent='Reconnexion…';await waitPhone(s);active--;send(it);return}active--;done++;it.li.className='err';s.textContent='Coupé';upd();next()};
x.send(it.f)}
/* Suivi après l'envoi : album et paroles trouvés sur l'iPhone */
const track={};let polling=false;
function detail(it,t,c){const d=it.li.querySelector('.n small');d.textContent=t;d.className=c||''}
async function poll(){if(polling)return;polling=true;while(Object.keys(track).length){await wait(2000);let r;try{r=await (await fetch('/api/recent',{cache:'no-store'})).json()}catch(e){continue}
for(const [name,it] of Object.entries(track)){const st=r[name];if(!st)continue;
if(st.state=='illisible'){detail(it,'Fichier illisible sur l’iPhone','bad');it.li.className='err';delete track[name];continue}
if(st.state!='ok')continue;delete track[name];
const ly={synchro:'paroles synchro ✓',texte:'paroles sans synchro',aucune:'sans paroles'}[st.lyrics]||'';
if(st.title)it.li.querySelector('.n b').textContent=st.title+(st.artist?' — '+st.artist:'');
if(st.id){const th=it.li.querySelector('.th');th.src='/api/cover?track='+st.id+'&s=120&v='+Date.now();th.onload=()=>th.style.visibility='visible'}
detail(it,(st.album||'Album introuvable')+' · '+ly+(st.cover?' · pochette ✓':''),st.album&&st.lyrics=='synchro'?'good':'');
if(st.album){const b=el('button','go');b.textContent=st.cover?'Changer la pochette':'Ajouter la pochette';b.onclick=()=>openAlbum(st.album);it.li.querySelector('.s').replaceWith(b)}}}polling=false}
function openAlbum(name){document.querySelector('.tab[data-t=art]').click();$('#q').value=name;lib=null;loadLib().then(()=>{const a=lib.find(x=>norm(x.title)==norm(name));if(a)select(a)})}
async function ping(){try{const r=await fetch('/api/ping',{cache:'no-store'});const ok=r.ok;setConn(ok);return ok}catch(e){setConn(false);return false}}
function setConn(ok){const c=$('#conn');c.className='conn '+(ok?'on':'off');c.querySelector('span').textContent=ok?'iPhone connecté':'iPhone injoignable : ouvre Platine sur l’iPhone'}
ping();setInterval(ping,4000);
function walk(e){if(e.isFile)e.file(add);else if(e.isDirectory){const r=e.createReader();const rd=()=>r.readEntries(es=>{if(es.length){es.forEach(walk);rd()}});rd()}}
/* Déposer n'importe où sur la page */
let depth=0;const veil=$('#veil');const musicOn=()=>$('#p-music').classList.contains('on');
window.addEventListener('dragenter',e=>{if(!musicOn()||!e.dataTransfer.types.includes('Files'))return;e.preventDefault();depth++;veil.classList.add('on')});
window.addEventListener('dragleave',e=>{if(!musicOn())return;depth=Math.max(0,depth-1);if(!depth)veil.classList.remove('on')});
window.addEventListener('dragover',e=>{if(musicOn())e.preventDefault()});
window.addEventListener('drop',e=>{if(!musicOn())return;e.preventDefault();depth=0;veil.classList.remove('on');const its=[...e.dataTransfer.items];if(its.length&&its[0].webkitGetAsEntry){its.forEach(i=>{const en=i.webkitGetAsEntry();if(en)walk(en)})}else[...e.dataTransfer.files].forEach(add)});
const d=$('#drop');['dragenter','dragover'].forEach(t=>d.addEventListener(t,e=>{e.preventDefault();d.classList.add('over')}));
['dragleave','drop'].forEach(t=>d.addEventListener(t,e=>{e.preventDefault();d.classList.remove('over')}));

$('#pick').onclick=e=>{e.stopPropagation();$('#file').click()};d.onclick=()=>$('#file').click();$('#file').onchange=e=>{[...e.target.files].forEach(add);e.target.value=''};
window.addEventListener('beforeunload',e=>{if(active||q.length||busy){e.preventDefault();e.returnValue=''}});

/* ---------- Pochettes ---------- */
let lib=null,sel=null,ed=null,busy=false;const ver={};
const coverURL=(a,s)=>`/api/cover?album=${encodeURIComponent(a.id)}&s=${s||300}&v=${ver[a.id]||0}`;
async function loadLib(){try{const r=await fetch('/api/library',{cache:'no-store'});lib=(await r.json()).albums;renderGrid()}catch(e){$('#grid').innerHTML='<div class="empty-ed">Impossible de lire la bibliothèque. Garde l’écran Envoi par Wi‑Fi ouvert sur l’iPhone.</div>'}}
function renderGrid(){const g=$('#grid'),k=norm($('#q').value);g.innerHTML='';
const items=lib.filter(a=>!k||norm(a.title+' '+a.artist).includes(k)||a.tracks.some(t=>norm(t.title).includes(k)));
if(!items.length){g.innerHTML='<div class="empty-ed">Aucun album.</div>';return}
items.forEach(a=>{const c=el('button','card'+(sel&&sel.id==a.id?' sel':''));const im=el('div','im');const img=el('img');img.loading='lazy';img.src=coverURL(a);img.onerror=()=>{img.remove()};im.appendChild(img);
if(a.animated){const b=el('span','badge');b.textContent='Animée';im.appendChild(b)}c.appendChild(im);const t=el('b');t.textContent=a.title;const s=el('span');s.textContent=a.artist+(a.tracks.length>1?` · ${a.tracks.length} sons`:'');c.append(t,s);c.onclick=()=>select(a);c.dataset.id=a.id;g.appendChild(c)})}
$('#q').oninput=()=>lib&&renderGrid();

function select(a){sel=a;ed=null;document.querySelectorAll('.card').forEach(c=>c.classList.toggle('sel',c.dataset.id==a.id));
const box=$('#ed');box.innerHTML=`<h2></h2><div class="who"></div>
<div class="stage empty" id="stage"><img id="cur" alt=""><div class="hint"><b>Dépose une nouvelle pochette</b><span>Image, GIF ou vidéo (pochette animée)</span></div></div>
<div class="row"><button class="btn ghost" id="choose">Choisir un fichier</button><input type="file" id="one" hidden accept="image/*,.gif,video/*,.mov,.mp4,.m4v"></div>
<div id="adj"></div>
<div class="target"><label><input type="radio" name="tg" value="album" checked> Tout l’album</label><label><input type="radio" name="tg" value="some"> Seulement certains sons</label><div class="tracks" id="tl" hidden></div></div>
<div class="row"><button class="btn" id="go" disabled>Envoyer sur l’iPhone</button></div><div class="bar" id="ebar" style="margin-top:12px;display:none"><i></i></div><div class="status" id="st"></div>`;
box.querySelector('h2').textContent=a.title;box.querySelector('.who').textContent=a.artist+(a.year?' · '+a.year:'');
const cur=$('#cur');cur.src=coverURL(a,800);cur.onerror=()=>cur.remove();
const tl=$('#tl');a.tracks.forEach(t=>{const l=el('label');const i=el('input');i.type='checkbox';i.value=t.id;l.append(i,document.createTextNode(' '+(t.n?t.n+'. ':'')+t.title));tl.appendChild(l)});
box.querySelectorAll('input[name=tg]').forEach(r=>r.onchange=()=>{tl.hidden=r.value!='some'||!r.checked});
const st=$('#stage');['dragenter','dragover'].forEach(t=>st.addEventListener(t,e=>{e.preventDefault();st.classList.add('over')}));
['dragleave','drop'].forEach(t=>st.addEventListener(t,e=>{e.preventDefault();st.classList.remove('over')}));
st.addEventListener('drop',e=>{const f=e.dataTransfer.files[0];if(f)loadFile(f)});
$('#choose').onclick=()=>$('#one').click();$('#one').onchange=e=>{const f=e.target.files[0];if(f)loadFile(f);e.target.value=''};
$('#go').onclick=sendArt;box.scrollIntoView({block:'nearest',behavior:'smooth'})}

function kindOf(f){const x=f.name.split('.').pop().toLowerCase();if(f.type.startsWith('video/')||['mp4','mov','m4v'].includes(x))return{kind:'video',ext:x=='mov'?'mov':'mp4'};if(x=='gif'||f.type=='image/gif')return{kind:'gif',ext:'gif'};return{kind:'image',ext:'jpg'}}
function loadFile(f){const k=kindOf(f),st=$('#stage');st.querySelectorAll('canvas,video,img').forEach(n=>n.remove());st.classList.remove('empty');$('#adj').innerHTML='';status('');
if(k.kind!='image'){const m=el(k.kind=='video'?'video':'img');m.src=URL.createObjectURL(f);if(k.kind=='video'){m.muted=true;m.loop=true;m.autoplay=true;m.playsInline=true}st.prepend(m);ed={...k,file:f};
$('#adj').innerHTML='<div class="status">'+(k.kind=='video'?'Vidéo envoyée telle quelle : elle devient la pochette animée.':'GIF envoyé tel quel : il devient la pochette animée.')+'</div>';$('#go').disabled=false;return}
const img=new Image();img.onload=()=>{ed={kind:'image',ext:'jpg',img,zoom:1,ox:0,oy:0,rot:0,b:100,c:100,s:100};const cv=el('canvas');cv.width=cv.height=800;st.prepend(cv);ed.cv=cv;controls();paint(cv.getContext('2d'),800);drag(cv);$('#go').disabled=false};
img.onerror=()=>status('Cette image ne peut pas être lue par le navigateur (essaie JPG ou PNG).','err');img.src=URL.createObjectURL(f)}

function controls(){const a=$('#adj');a.innerHTML=`<div class="ctl"><span>Zoom</span><input type="range" id="z" min="1" max="4" step=".01" value="1">
<span>Luminosité</span><input type="range" id="lb" min="50" max="150" value="100"><span>Contraste</span><input type="range" id="lc" min="50" max="150" value="100"><span>Saturation</span><input type="range" id="ls" min="0" max="200" value="100"></div>
<div class="row"><button class="btn ghost" id="rot">↻ Pivoter</button><button class="btn ghost" id="ctr">Recentrer</button><button class="btn ghost" id="rst">Réinitialiser</button></div>`;
const bind=(id,key)=>$(id).oninput=e=>{ed[key]=+e.target.value;redraw()};bind('#z','zoom');bind('#lb','b');bind('#lc','c');bind('#ls','s');
$('#rot').onclick=()=>{ed.rot=(ed.rot+90)%360;redraw()};$('#ctr').onclick=()=>{ed.ox=ed.oy=0;redraw()};
$('#rst').onclick=()=>{Object.assign(ed,{zoom:1,ox:0,oy:0,rot:0,b:100,c:100,s:100});controls();redraw()}}
function dims(S){const e=ed,rw=e.rot%180?e.img.height:e.img.width,rh=e.rot%180?e.img.width:e.img.height,k=S/Math.min(rw,rh)*e.zoom;return{k,mx:Math.max(0,(rw*k-S)/2/S),my:Math.max(0,(rh*k-S)/2/S)}}
function clamp(){const m=dims(1000);ed.ox=Math.min(m.mx,Math.max(-m.mx,ed.ox));ed.oy=Math.min(m.my,Math.max(-m.my,ed.oy))}
function paint(ctx,S){const e=ed;clamp();const {k}=dims(S);ctx.save();ctx.fillStyle='#000';ctx.fillRect(0,0,S,S);ctx.filter=`brightness(${e.b}%) contrast(${e.c}%) saturate(${e.s}%)`;
ctx.translate(S/2+e.ox*S,S/2+e.oy*S);ctx.rotate(e.rot*Math.PI/180);ctx.scale(k,k);ctx.imageSmoothingQuality='high';ctx.drawImage(e.img,-e.img.width/2,-e.img.height/2);ctx.restore()}
let raf=0;function redraw(){cancelAnimationFrame(raf);raf=requestAnimationFrame(()=>paint(ed.cv.getContext('2d'),800))}
function drag(cv){let p=null;cv.onpointerdown=e=>{p={x:e.clientX,y:e.clientY};cv.setPointerCapture(e.pointerId)};
cv.onpointermove=e=>{if(!p)return;const w=cv.clientWidth;ed.ox+=(e.clientX-p.x)/w;ed.oy+=(e.clientY-p.y)/w;p={x:e.clientX,y:e.clientY};redraw()};cv.onpointerup=cv.onpointercancel=()=>p=null;
cv.onwheel=e=>{e.preventDefault();ed.zoom=Math.min(4,Math.max(1,ed.zoom*(e.deltaY<0?1.06:1/1.06)));const z=$('#z');if(z)z.value=ed.zoom;redraw()}}
function status(t,c){const s=$('#st');if(!s)return;s.textContent=t;s.className='status '+(c||'')}
function render(e,S){const cv=el('canvas');cv.width=cv.height=S;const prev=ed;ed=e;paint(cv.getContext('2d'),S);ed=prev;return new Promise(r=>cv.toBlob(r,'image/jpeg',.92))}
function put(url,body,onp){return new Promise(res=>{const x=new XMLHttpRequest();x.open('PUT',url);if(onp)x.upload.onprogress=e=>onp(e.loaded/(e.total||1));x.onload=()=>res(x.status==200);x.onerror=()=>res(false);x.send(body)})}
async function sendArt(){if(!ed||!sel)return;let target;const some=document.querySelector('input[name=tg][value=some]').checked;
if(some){const ids=[...document.querySelectorAll('#tl input:checked')].map(i=>i.value);if(!ids.length){status('Coche au moins un son.','err');return}target='tracks='+ids.join(',')}else target='album='+encodeURIComponent(sel.id);
const body=ed.kind=='image'?await render(ed,3000):ed.file;$('#go').disabled=true;busy=true;const bar=$('#ebar');bar.style.display='block';status('Envoi…');
const okk=await put(`/api/artwork?ext=${ed.ext}&${target}`,body,p=>bar.querySelector('i').style.width=(p*100)+'%');busy=false;$('#go').disabled=false;
if(okk){status('✓ Pochette posée sur l’iPhone','ok');ver[sel.id]=Date.now();if(ed.kind!='image')sel.animated=true;renderGrid()}else status('L’envoi a échoué. L’écran Envoi par Wi‑Fi est-il toujours ouvert ?','err')}

/* ---------- Plusieurs pochettes ---------- */
let bulk=[];$('#bulkBtn').onclick=()=>{if(!lib){loadLib();return}$('#bulk').click()};
$('#bulk').onchange=e=>{bulk=[...e.target.files].map(f=>({f,a:guess(f.name)}));e.target.value='';showBulk()};
function guess(name){const n=norm(name.replace(/\.[^.]+$/,''));let best=null,score=0;for(const a of lib){const t=norm(a.title),ar=norm(a.artist);let s=0;
if(n==t||n==norm(a.artist+a.title)||n==norm(a.title+a.artist))s=3;else if(t.length>=4&&n.includes(t))s=2+(ar&&n.includes(ar)?.5:0);else if(n.length>=4&&t.includes(n))s=1;if(s>score){score=s;best=a}}return best}
function showBulk(){const L=$('#bulkList');L.innerHTML='';bulk.forEach(b=>{const r=el('div','bl');const k=kindOf(b.f);const th=el(k.kind=='video'?'video':'img');th.src=URL.createObjectURL(b.f);if(k.kind=='video'){th.muted=true;th.style.cssText='width:56px;height:56px;object-fit:cover;border-radius:8px'}
const n=el('div','n');n.textContent=b.f.name;const s=el('select');s.innerHTML='<option value="">— Ne pas envoyer —</option>'+lib.map((a,i)=>`<option value="${i}">${esc(a.title)} — ${esc(a.artist)}</option>`).join('');if(b.a)s.value=lib.indexOf(b.a);s.onchange=()=>b.a=s.value===''?null:lib[+s.value];
const st=el('div');st.style.color='var(--muted)';b.st=st;r.append(th,n,s,st);L.appendChild(r)});$('#dlg').showModal()}
const esc=s=>(s||'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
$('#bulkCancel').onclick=()=>$('#dlg').close();
$('#bulkSend').onclick=async()=>{busy=true;$('#bulkSend').disabled=true;for(const b of bulk){if(!b.a){b.st.textContent='—';continue}b.st.textContent='…';const k=kindOf(b.f);let body=b.f;
if(k.kind=='image'){const img=await new Promise(r=>{const i=new Image();i.onload=()=>r(i);i.onerror=()=>r(null);i.src=URL.createObjectURL(b.f)});if(!img){b.st.textContent='Illisible';continue}body=await render({img,zoom:1,ox:0,oy:0,rot:0,b:100,c:100,s:100},3000)}
const r=await put(`/api/artwork?ext=${k.ext}&album=${encodeURIComponent(b.a.id)}`,body);b.st.textContent=r?'✓':'Erreur';b.st.style.color=r?'var(--ok)':'var(--accent)';if(r){ver[b.a.id]=Date.now();if(k.kind!='image')b.a.animated=true}}
busy=false;$('#bulkSend').disabled=false;renderGrid()};
</script></body></html>
"""#
}


// MARK: - Chaque import (Fichiers, dossier Platine ou Wi-Fi) : album, pochette et paroles trouvés tout seuls

@MainActor
final class ImportEnricher {
    static let shared = ImportEnricher()
    private var queue: [(file: String, id: UUID)] = []
    private var running = false
    private weak var library: Library?

    func handle(_ added: [(file: String, id: UUID)], all: [String], library: Library) {
        self.library = library
        WifiTransfer.shared.imported(added, all: all)
        queue += added
        run()
    }

    private func run() {
        guard !running, !queue.isEmpty, let library else { return }
        running = true
        let next = queue.removeFirst()
        Task {
            let r = await TrackEnricher.enrich(next.id, library: library)
            WifiTransfer.shared.enriched(next.file, r)
            running = false
            run()
        }
    }
}

import SwiftUI

/// Mode voyage : tout préparer pour écouter sans connexion (paroles, pochettes animées),
/// et savoir combien de jours il reste avant de devoir renouveler l'app.
struct TravelModeView: View {
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var preparing = false
    @State private var done = 0
    @State private var total = 0
    @State private var found = 0
    @State private var finished = false
    @State private var task: Task<Void, Never>?

    private var lyricsReady: Int { library.tracks.filter { !($0.lyrics ?? "").isEmpty }.count }
    private var animatedTracks: [(URL, ArtworkKind)] {
        var seen = Set<URL>()
        var result: [(URL, ArtworkKind)] = []
        for t in library.tracks {
            let kind = library.artworkKind(t)
            guard kind == .video || kind == .gif, let url = library.artworkURL(t), seen.insert(url).inserted else { continue }
            result.append((url, kind))
        }
        return result
    }

    var body: some View {
        let animated = animatedTracks
        let clipsReady = animated.filter { LockScreenArtwork.isPrepared(source: $0.0) }.count
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "airplane.departure")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(.tint)
                        .symbolEffect(.bounce, value: finished)
                    Text("Mode voyage").font(.title2.bold())
                    Text("Tout est prêt pour écouter sans connexion")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .listRowBackground(Color.clear)
            }

            Section {
                status("Tes sons", value: "\(library.tracks.count) dans l’iPhone", ok: true, symbol: "music.note")
                status("Paroles", value: "\(lyricsReady) sur \(library.tracks.count)",
                       ok: lyricsReady == library.tracks.count, symbol: "quote.bubble")
                if !animated.isEmpty {
                    status("Pochettes animées (écran verrouillé)", value: "\(clipsReady) sur \(animated.count)",
                           ok: clipsReady == animated.count, symbol: "sparkles.rectangle.stack")
                }
                expirationRow
            } header: {
                Text("État")
            } footer: {
                Text("Tes sons, pochettes et réglages sont dans l’iPhone : ils marchent toujours sans connexion. Seules la recherche de paroles et le renouvellement de l’app ont besoin d’internet.")
            }

            Section {
                if preparing {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Recherche des paroles…")
                            Spacer()
                            Text("\(done)/\(total)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                    }
                    Button("Arrêter", role: .destructive) { task?.cancel() }
                } else {
                    Button {
                        prepare()
                    } label: {
                        Label("Tout préparer", systemImage: "suitcase.rolling.fill")
                            .font(.body.weight(.semibold))
                    }
                    if finished {
                        Text(found > 0 ? "\(found) paroles ajoutées. Tout ce qui pouvait être préparé l’est."
                                       : "C’est prêt. Aucune nouvelle parole trouvée.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("À faire avec le Wi-Fi, juste avant de partir. L’app cherche les paroles manquantes et prépare les pochettes animées de l’écran verrouillé. Garde l’app ouverte pendant ce temps.")
            }
        }
        .navigationTitle("Mode voyage")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { task?.cancel() }
    }

    @ViewBuilder private var expirationRow: some View {
        if let end = AppSigning.expiration {
            let days = max(0, Calendar.current.dateComponents([.day], from: Date(), to: end).day ?? 0)
            status("Renouvellement de l’app",
                   value: days == 0 ? "Aujourd’hui !" : "Dans \(days) jour\(days > 1 ? "s" : "")",
                   ok: days >= 3, symbol: "clock.arrow.circlepath")
            Text("L’app s’arrêtera le " + end.formatted(date: .complete, time: .shortened)
                 + ". Renouvelle-la avec iLoader ou SideStore avant de partir pour avoir les 7 jours complets.")
                .font(.footnote)
                .foregroundStyle(days >= 3 ? Color.secondary : Color.orange)
        } else {
            status("Renouvellement de l’app", value: "Inconnu", ok: true, symbol: "clock.arrow.circlepath")
        }
    }

    private func status(_ title: String, value: String, ok: Bool, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 26)
                .foregroundStyle(.tint)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
        }
    }

    private func prepare() {
        finished = false
        found = 0
        // Pochettes animées : préparées une par une pendant que l'app est ouverte.
        for (url, kind) in animatedTracks {
            LockScreenArtwork.shared.warm(source: url, kind: kind)
        }
        let missing = library.tracks.filter { ($0.lyrics ?? "").isEmpty }
        total = missing.count
        done = 0
        preparing = true
        task = Task { @MainActor in
            for t in missing {
                if Task.isCancelled { break }
                if let text = await LyricsService.search(title: t.title, artist: t.artist, duration: t.duration) {
                    library.setLyrics(t.id, text)
                    found += 1
                }
                done += 1
                // Petite pause : le service de paroles n'aime pas être sollicité trop vite.
                try? await Task.sleep(for: .milliseconds(150))
            }
            preparing = false
            finished = true
        }
    }
}

/// Date d'expiration de la signature de l'app (lue dans son profil d'installation).
enum AppSigning {
    static let expiration: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)),
              start.lowerBound < end.upperBound else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["ExpirationDate"] as? Date
    }()
}

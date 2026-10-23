import SwiftUI

/// Réglages : lecture, apparence, bibliothèque, stockage.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(UIState.self) private var ui
    @State private var confirmDelete = false
    @State private var storage: Int64 = 0

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Fondu entre les morceaux", isOn: $settings.fadeTransitions)
                if settings.fadeTransitions {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Durée du fondu")
                            Spacer()
                            Text("\(Int(settings.fadeDuration)) s").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.fadeDuration, in: 1...12, step: 1)
                    }
                }
                Picker("Vitesse de lecture", selection: Binding(get: { settings.playbackSpeed }, set: { player.setSpeed($0) })) {
                    ForEach(AppSettings.speeds, id: \.self) { Text(AppSettings.speedLabel($0)).tag($0) }
                }
                Toggle("Pause si les écouteurs sont retirés", isOn: $settings.pauseOnDisconnect)
            } header: {
                Text("Lecture")
            } footer: {
                Text("Le fondu baisse le son à la fin d’un morceau et le remonte au début du suivant.")
            }

            Section {
                if player.sleepActive {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        LabeledContent("État", value: sleepStatus(at: context.date))
                    }
                    Button("Désactiver la minuterie", role: .destructive) { player.setSleepTimer(minutes: nil) }
                } else {
                    Menu {
                        ForEach([15, 30, 45, 60, 90], id: \.self) { m in
                            Button("\(m) minutes") { player.setSleepTimer(minutes: m) }
                        }
                        Button("À la fin du morceau") { player.setSleepAtTrackEnd() }
                    } label: {
                        Label("Lancer la minuterie", systemImage: "moon.zzz")
                    }
                }
            } header: {
                Text("Minuterie de sommeil")
            } footer: {
                Text("La musique s’arrête doucement à la fin du temps choisi.")
            }

            Section("Apparence") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Couleur d’accent")
                    HStack(spacing: 12) {
                        ForEach(AccentChoice.allCases) { choice in
                            Button { settings.accent = choice } label: {
                                Circle()
                                    .fill(choice.color)
                                    .frame(width: 34, height: 34)
                                    .overlay {
                                        if settings.accent == choice {
                                            Image(systemName: "checkmark")
                                                .font(.footnote.weight(.bold))
                                                .foregroundStyle(.black)
                                        }
                                    }
                                    .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(choice.label)
                            .accessibilityAddTraits(settings.accent == choice ? AccessibilityTraits.isSelected : AccessibilityTraits())
                        }
                    }
                }
                .padding(.vertical, 4)
                Toggle("Fond aux couleurs de la pochette", isOn: $settings.dynamicBackground)
                Toggle("Pochettes animées", isOn: $settings.animatedArtwork)
                NavigationLink {
                    AppIconPicker()
                } label: {
                    HStack {
                        Text("Icône de l’app")
                        Spacer()
                        Text(AppIconChoice.all.first { $0.iconName == UIApplication.shared.alternateIconName }?.title ?? "Platine")
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Retours haptiques", isOn: $settings.haptics)
                Picker("Format dans la Collection", selection: $settings.shelfFormat) {
                    ForEach(AlbumFormat.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                Picker("Trier les morceaux par", selection: $settings.songSort) {
                    ForEach(SongSort.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Importer depuis le dossier Platine", isOn: $settings.autoImport)
                Button {
                    ui.importing = true
                } label: {
                    Label("Importer de la musique", systemImage: "plus.circle")
                }
            } header: {
                Text("Bibliothèque")
            } footer: {
                Text("Les fichiers déposés dans le dossier Platine (app Fichiers, ou iTunes sur PC) sont ajoutés à chaque ouverture.")
            }

            Section("Stockage") {
                LabeledContent("Morceaux", value: "\(library.tracks.count)")
                LabeledContent("Playlists", value: "\(library.playlists.count)")
                LabeledContent("Durée totale", value: formatDuration(library.totalDuration))
                LabeledContent("Espace utilisé", value: ByteCountFormatter.string(fromByteCount: storage, countStyle: .file))
                Button("Supprimer toute la bibliothèque", role: .destructive) { confirmDelete = true }
                    .disabled(library.tracks.isEmpty && library.playlists.isEmpty)
            }

            Section {
                LabeledContent("Version", value: "2.0")
            } footer: {
                Text("Platine lit ta propre musique. Seule la recherche de paroles contacte internet (LRCLIB), et uniquement quand tu ouvres des paroles absentes ou lances la recherche.")
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Réglages")
        .background { AmbientBackground(track: player.currentID.flatMap { library.track($0) }, dim: 0.65) }
        .task(id: library.tracks.count) { storage = library.storageBytes() }
        .confirmationDialog("Supprimer toute la bibliothèque ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Tout supprimer", role: .destructive) {
                player.stopAll()
                library.removeAll()
            }
        } message: {
            Text("Tes morceaux, pochettes et playlists seront effacés de Platine. Les fichiers d’origine ne sont pas touchés.")
        }
    }

    private func sleepStatus(at date: Date) -> String {
        if player.sleepAtTrackEnd { return "Arrêt à la fin du morceau" }
        guard let end = player.sleepEndDate else { return "Désactivée" }
        return "Arrêt dans " + formatTime(max(0, end.timeIntervalSince(date)))
    }
}

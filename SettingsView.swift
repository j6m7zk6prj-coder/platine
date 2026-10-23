import SwiftUI

/// Réglages : lecture, apparence, bibliothèque, stockage.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(UIState.self) private var ui
    @State private var confirmDelete = false
    @State private var storage: Int64 = 0
    @State private var lockBytes: Int64 = 0

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
                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    HStack {
                        Label("Thème et affichage", systemImage: "paintpalette")
                        Spacer()
                        Text(settings.theme.label).foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    AppIconPicker()
                } label: {
                    HStack {
                        Label("Icône de l’app", systemImage: "app.badge")
                        Spacer()
                        Text(AppIconChoice.all.first { $0.iconName == UIApplication.shared.alternateIconName }?.title ?? "Platine")
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Retours haptiques", isOn: $settings.haptics)
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
                LabeledContent("Clips de l’écran verrouillé", value: ByteCountFormatter.string(fromByteCount: lockBytes, countStyle: .file))
                if lockBytes > 0 {
                    Button("Vider les clips (refaits au besoin)") {
                        LockScreenArtwork.shared.clear()
                        lockBytes = 0
                        player.updateNowPlaying()
                    }
                }
                Button("Supprimer toute la bibliothèque", role: .destructive) { confirmDelete = true }
                    .disabled(library.tracks.isEmpty && library.playlists.isEmpty)
            }

            Section {
                LabeledContent("Version", value: "3.1")
            } footer: {
                Text("Platine lit ta propre musique. Seule la recherche de paroles contacte internet (LRCLIB), et uniquement quand tu ouvres des paroles absentes ou lances la recherche.")
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Réglages")
        .background { AmbientBackground(track: player.currentID.flatMap { library.track($0) }, dim: 0.65) }
        .task(id: library.tracks.count) {
            storage = library.storageBytes()
            lockBytes = LockScreenArtwork.cacheBytes()
        }
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


// MARK: - Apparence

/// Thème, couleur d'accent, pochettes, paroles et Collection.
struct AppearanceSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player

    private var lockFooter: String {
        if #available(iOS 26.0, *) {
            return "Les pochettes vidéo ou GIF s’animent en plein écran quand l’iPhone est verrouillé. La première fois, Platine prépare le clip en quelques secondes."
        }
        return "Nécessite iOS 26 ou plus récent."
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 14) {
                    ForEach(AppTheme.allCases) { theme in
                        ThemeTile(theme: theme, selected: settings.theme == theme) {
                            withAnimation(.smooth(duration: 0.35)) { settings.theme = theme }
                        }
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Thème")
            } footer: {
                Text(settings.theme.detail + ". L’écran « En lecture » et la Collection restent toujours sombres, comme dans Musique.")
            }

            Section("Couleur d’accent") {
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
                                            .foregroundStyle(choice == .white ? Color.black : Color.white)
                                    }
                                }
                                .overlay { Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.label)
                        .accessibilityAddTraits(settings.accent == choice ? AccessibilityTraits.isSelected : AccessibilityTraits())
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Fond") {
                Toggle("Couleurs de la pochette en lecture", isOn: $settings.dynamicBackground)
                Toggle("Fond en mouvement", isOn: $settings.backgroundMotion)
            }

            Section("Pochettes") {
                Picker("Forme", selection: $settings.artworkStyle) {
                    ForEach(ArtworkStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Pochettes animées", isOn: $settings.animatedArtwork)
            }

            Section {
                Toggle("Pochette animée sur l’écran verrouillé", isOn: $settings.lockScreenAnimation)
                    .onChange(of: settings.lockScreenAnimation) { _, _ in player.updateNowPlaying() }
            } header: {
                Text("Écran verrouillé")
            } footer: {
                Text(lockFooter)
            }

            Section {
                Picker("Taille", selection: $settings.lyricsSize) {
                    ForEach(LyricsSize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Les paroles brillent doucement")
                    .font(.system(size: settings.lyricsSize.points * 0.8, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .white.opacity(0.55), radius: 2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.1)))
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                    .animation(.smooth(duration: 0.25), value: settings.lyricsSize)
            } header: {
                Text("Paroles")
            }

            Section {
                Toggle("Stickers automatiques", isOn: Binding(get: { library.autoStickers },
                                                              set: { library.autoStickers = $0 }))
            } header: {
                Text("Collection")
            } footer: {
                Text("Ajoute tout seul les stickers Or, Platine, Favori et Nouveau. Pour choisir tes propres stickers holographiques, appuie longtemps sur un album dans la Collection.")
            }

            Section("Bibliothèque") {
                Toggle("Afficher « Ajoutés récemment »", isOn: $settings.showRecent)
                Picker("Format dans la Collection", selection: $settings.shelfFormat) {
                    ForEach(AlbumFormat.choosable) { Text($0.label).tag($0) }
                }
            }
        }
        .navigationTitle("Apparence")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ThemeTile: View {
    let theme: AppTheme
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: theme.swatch, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 64)
                    .overlay(alignment: .bottomLeading) {
                        // Mini aperçu : deux lignes de texte dans la couleur du thème.
                        VStack(alignment: .leading, spacing: 4) {
                            Capsule().frame(width: 38, height: 6)
                            Capsule().frame(width: 24, height: 6).opacity(0.5)
                        }
                        .foregroundStyle(theme.isLight ? Color.black.opacity(0.75) : Color.white.opacity(0.85))
                        .padding(10)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.15)),
                                          lineWidth: selected ? 2.5 : 1)
                    }
                Text(theme.label)
                    .font(.footnote.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Thème " + theme.label)
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }
}

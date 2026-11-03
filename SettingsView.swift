import SwiftUI

// MARK: - Réglages (ouverts depuis l'icône de profil d'« Écouter »)

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var ui: UIState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmErase = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Apparence") {
                    Picker("Mode", selection: $settings.appearance) {
                        Text("Comme l’iPhone").tag(AppearanceMode.auto)
                        Text("Clair").tag(AppearanceMode.light)
                        Text("Sombre").tag(AppearanceMode.dark)
                    }
                }

                Section("Lecture") {
                    Toggle("Fondu entre les morceaux", isOn: $settings.fadeTransitions)
                    if settings.fadeTransitions {
                        Stepper("Durée du fondu : \(Int(settings.fadeDuration)) s", value: $settings.fadeDuration, in: 1...12, step: 1)
                    }
                    Toggle("Pause si les écouteurs sont retirés", isOn: $settings.pauseOnDisconnect)
                    Toggle("Lecteur sur l’écran verrouillé", isOn: $settings.lockScreenPlayer)
                        .onChange(of: settings.lockScreenPlayer) { _ in player.applyLockScreenPlayer() }
                    Toggle("Retours haptiques", isOn: $settings.haptics)
                }

                Section("Paroles") {
                    Picker("Taille du texte", selection: $settings.lyricsSize) {
                        Text("Petite").tag(LyricsSize.small)
                        Text("Moyenne").tag(LyricsSize.medium)
                        Text("Grande").tag(LyricsSize.large)
                    }
                }

                Section {
                    Button("Importer de la musique") {
                        dismiss()
                        ui.importing = true
                    }
                    Toggle("Importer depuis le dossier Platine", isOn: $settings.autoImport)
                } header: {
                    Text("Bibliothèque")
                } footer: {
                    Text("Dépose des fichiers dans « Sur mon iPhone › Platine » (app Fichiers) ou depuis iTunes sur ton ordinateur : ils sont ajoutés à l’ouverture de l’app.")
                }

                Section("Infos") {
                    LabeledContent("Morceaux", value: "\(library.tracks.count)")
                    LabeledContent("Espace utilisé", value: ByteCountFormatter.string(fromByteCount: library.storageBytes(), countStyle: .file))
                    LabeledContent("Version", value: "Lite 1.0 (iOS 16)")
                }

                Section {
                    Button("Supprimer toute la musique", role: .destructive) { confirmErase = true }
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }.fontWeight(.semibold)
                }
            }
            .confirmationDialog("Supprimer toute la musique ?", isPresented: $confirmErase, titleVisibility: .visible) {
                Button("Tout supprimer", role: .destructive) {
                    player.stopAll()
                    library.removeAll()
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Les fichiers audio, les pochettes et les playlists de Platine seront effacés de l’iPhone.")
            }
        }
    }
}

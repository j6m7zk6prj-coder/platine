import SwiftUI

@main
struct PlatineApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var library: Library
    @StateObject private var player: Player
    @StateObject private var ui: UIState

    init() {
        let s = AppSettings()
        let lib = Library()
        _settings = StateObject(wrappedValue: s)
        _library = StateObject(wrappedValue: lib)
        _player = StateObject(wrappedValue: Player(library: lib, settings: s))
        _ui = StateObject(wrappedValue: UIState())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(settings)
                .environmentObject(ui)
                // Clair, sombre, ou comme l'iPhone.
                .preferredColorScheme(settings.appearance == .light ? .light : (settings.appearance == .dark ? .dark : nil))
                .tint(.music)
        }
    }
}

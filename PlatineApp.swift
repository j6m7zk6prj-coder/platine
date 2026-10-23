import SwiftUI

@main
struct PlatineApp: App {
    @State private var settings: AppSettings
    @State private var library: Library
    @State private var player: Player
    @State private var ui: UIState

    init() {
        let s = AppSettings()
        let lib = Library()
        _settings = State(initialValue: s)
        _library = State(initialValue: lib)
        _player = State(initialValue: Player(library: lib, settings: s))
        _ui = State(initialValue: UIState())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(player)
                .environment(settings)
                .environment(ui)
                .preferredColorScheme(.dark)
                .tint(settings.accent.color)
        }
    }
}

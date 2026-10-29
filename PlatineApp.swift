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
                .modifier(SystemAppearanceReader())
                .environment(library)
                .environment(player)
                .environment(settings)
                .environment(ui)
                // Mode Auto : on suit le réglage de l'iPhone ; sinon le thème décide.
                .preferredColorScheme(settings.appearance == .light ? .light : (settings.appearance == .dark ? .dark : nil))
                .tint(settings.tint)
        }
    }
}


/// Lit si l'iPhone est en mode clair ou sombre (pour le mode Auto).
struct SystemAppearanceReader: ViewModifier {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .onAppear { update() }
            .onChange(of: scheme) { _, _ in update() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in update() }
    }

    private func update() {
        // En mode Auto, la couleur de l'écran suit l'iPhone : on la lit directement à la source.
        let style = UIScreen.main.traitCollection.userInterfaceStyle
        let light = settings.appearance == .auto ? style != .dark : scheme == .light
        if settings.systemIsLight != light { settings.systemIsLight = light }
    }
}

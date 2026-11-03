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
                .modifier(SystemAppearanceReader())
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(settings)
                .environmentObject(ui)
                // Mode Auto : on suit le réglage de l'iPhone ; sinon le thème décide.
                .preferredColorScheme(settings.appearance == .light ? .light : (settings.appearance == .dark ? .dark : nil))
                .tint(settings.tint)
        }
    }
}


/// Lit si l'iPhone est en mode clair ou sombre (pour le mode Auto).
struct SystemAppearanceReader: ViewModifier {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .onAppear { update() }
            .onChangeCompat(of: scheme) { _, _ in update() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in update() }
    }

    private func update() {
        // En mode Auto, la couleur de l'écran suit l'iPhone : on la lit directement à la source.
        let style = UIScreen.main.traitCollection.userInterfaceStyle
        let light = settings.appearance == .auto ? style != .dark : scheme == .light
        if settings.systemIsLight != light { settings.systemIsLight = light }
    }
}

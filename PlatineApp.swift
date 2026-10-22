import SwiftUI

@main
struct PlatineApp: App {
    @State private var library: Library
    @State private var player: Player

    init() {
        let lib = Library()
        _library = State(initialValue: lib)
        _player = State(initialValue: Player(library: lib))
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .environment(player)
                .preferredColorScheme(.dark)
                .tint(.white)
        }
    }
}

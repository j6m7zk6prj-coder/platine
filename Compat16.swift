import SwiftUI
import UIKit

// MARK: - Version iOS 16 (iPhone 8)
// Ce fichier remplace les outils qui n'existent qu'à partir d'iOS 17, avec le même rendu.

// MARK: Vibrations

/// Les vibrations de l'app (remplace `sensoryFeedback`, réservé à iOS 17).
struct Haptic: Equatable {
    enum Weight { case light, medium, heavy }
    enum Flexibility { case rigid, solid, soft }
    fileprivate enum Kind: Equatable { case selection, success, warning, error, impact(UIImpactFeedbackGenerator.FeedbackStyle, CGFloat) }
    fileprivate let kind: Kind

    static let selection = Haptic(kind: .selection)
    static let success = Haptic(kind: .success)
    static let warning = Haptic(kind: .warning)
    static let error = Haptic(kind: .error)

    static func impact(weight: Weight = .medium, intensity: Double = 1) -> Haptic {
        let style: UIImpactFeedbackGenerator.FeedbackStyle
        switch weight {
        case .light: style = .light
        case .medium: style = .medium
        case .heavy: style = .heavy
        }
        return Haptic(kind: .impact(style, CGFloat(intensity)))
    }

    static func impact(flexibility: Flexibility, intensity: Double = 1) -> Haptic {
        let style: UIImpactFeedbackGenerator.FeedbackStyle
        switch flexibility {
        case .rigid: style = .rigid
        case .solid: style = .heavy
        case .soft: style = .soft
        }
        return Haptic(kind: .impact(style, CGFloat(intensity)))
    }

    @MainActor func play() {
        switch kind {
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .impact(let style, let intensity): UIImpactFeedbackGenerator(style: style).impactOccurred(intensity: intensity)
        }
    }
}

private struct HapticOnChange<T: Equatable>: ViewModifier {
    let trigger: T
    let make: (T, T) -> Haptic?
    @State private var old: T?

    func body(content: Content) -> some View {
        content
            .onAppear { old = trigger }
            .onChange(of: trigger) { new in
                let previous = old ?? new
                old = new
                make(previous, new)?.play()
            }
    }
}

extension View {
    /// Vibration à chaque changement de `trigger`.
    func haptic<T: Equatable>(_ feedback: Haptic, trigger: T) -> some View {
        modifier(HapticOnChange(trigger: trigger, make: { _, _ in feedback }))
    }

    /// Vibration choisie selon l'ancienne et la nouvelle valeur (`nil` : aucune).
    func haptic<T: Equatable>(trigger: T, _ make: @escaping (T, T) -> Haptic?) -> some View {
        modifier(HapticOnChange(trigger: trigger, make: make))
    }
}

// MARK: Suivre un changement avec l'ancienne et la nouvelle valeur

private struct OnChangeCompat<V: Equatable>: ViewModifier {
    let value: V
    let initial: Bool
    let action: (V, V) -> Void
    @State private var old: V?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if old == nil {
                    old = value
                    if initial { action(value, value) }
                }
            }
            .onChange(of: value) { new in
                let previous = old ?? new
                old = new
                action(previous, new)
            }
    }
}

extension View {
    /// Comme `onChange` d'iOS 17 : l'action reçoit l'ancienne et la nouvelle valeur.
    func onChangeCompat<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping (V, V) -> Void) -> some View {
        modifier(OnChangeCompat(value: value, initial: initial, action: action))
    }
}

// MARK: Boutons avec icône

/// `Button("Titre", systemImage: "icône")` n'existe qu'à partir d'iOS 17 : même chose ici.
struct IconButton: View {
    let title: String
    let systemImage: String
    var role: ButtonRole?
    let action: () -> Void

    init(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
        }
    }
}

// MARK: Écran vide (« Aucun morceau »…)

/// Remplace `ContentUnavailableView` (iOS 17), avec les mêmes façons de l'écrire.
struct ContentUnavailableView<L: View, D: View, A: View>: View {
    private let label: L
    private let description: D
    private let actions: A

    init(@ViewBuilder label: () -> L, @ViewBuilder description: () -> D, @ViewBuilder actions: () -> A) {
        self.label = label()
        self.description = description()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 10) {
            label.labelStyle(UnavailableLabelStyle())
            description
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions.padding(.top, 8)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension ContentUnavailableView where A == EmptyView {
    init(@ViewBuilder label: () -> L, @ViewBuilder description: () -> D) {
        self.init(label: label, description: description, actions: { EmptyView() })
    }
}

extension ContentUnavailableView where L == Label<Text, Image>, D == Text?, A == EmptyView {
    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.init(label: { Label(title, systemImage: systemImage) }, description: { description }, actions: { EmptyView() })
    }
}

private struct UnavailableLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 12) {
            configuration.icon
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            configuration.title
                .font(.title2.bold())
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: Défilement page par page à la verticale (comme TikTok)

/// Remplace le défilement « paging » d'iOS 17 : une page par élément, on glisse vers le haut ou le bas.
/// Seules la page affichée et ses deux voisines existent (léger pour l'iPhone 8).
struct VerticalPager<Item: Identifiable, Page: View>: View where Item.ID: Hashable {
    let items: [Item]
    @Binding var selection: Item.ID?
    @ViewBuilder var page: (Item) -> Page
    /// Le doigt sur l'écran. Remis à zéro tout seul, même si iOS interrompt le geste
    /// (c'est ce qui laissait l'écran bloqué entre deux pages).
    @GestureState private var finger: CGFloat = 0
    /// Ce qui reste du geste quand on lâche : il revient à zéro en douceur avec le changement de page.
    @State private var settle: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let index = items.firstIndex { $0.id == selection } ?? 0
            let shown = items.indices.filter { abs($0 - index) <= 1 }
            let shift = finger + settle
            ZStack(alignment: .top) {
                ForEach(shown, id: \.self) { i in
                    page(items[i])
                        .frame(width: w, height: h)
                        .clipped()
                        .offset(y: CGFloat(i - index) * h + shift)
                }
            }
            .frame(width: w, height: h, alignment: .top)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 14)
                    .updating($finger) { g, state, _ in
                        guard abs(g.translation.height) > abs(g.translation.width) else { return }
                        var y = g.translation.height
                        if (index == 0 && y > 0) || (index == items.count - 1 && y < 0) { y /= 3 }
                        state = y
                    }
                    .onEnded { g in
                        guard abs(g.translation.height) > abs(g.translation.width) else { return }
                        let moved = g.translation.height, flick = g.predictedEndTranslation.height
                        var target = index
                        if (moved < -h * 0.18 || flick < -h * 0.45), index < items.count - 1 { target = index + 1 }
                        if (moved > h * 0.18 || flick > h * 0.45), index > 0 { target = index - 1 }
                        // Le nouveau point de départ tient compte du changement de page : rien ne saute.
                        var start = moved
                        if (index == 0 && start > 0) || (index == items.count - 1 && start < 0) { start /= 3 }
                        if target != index { start += CGFloat(target - index) * h }
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) {
                            if target != index { selection = items[target].id }
                            settle = start
                        }
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.92)) { settle = 0 }
                    }
            )
        }
    }
}

// MARK: Petits iPhone (iPhone 8, SE)

enum Device {
    /// Écran de 4,7 pouces ou moins (iPhone 8, SE) : on resserre un peu les espacements.
    static let isSmallScreen: Bool = UIScreen.main.bounds.height < 700
    /// Moins de 3 Go de mémoire (iPhone 8 : 2 Go) : la 3D et les effets sont allégés.
    static let isLowEnd: Bool = ProcessInfo.processInfo.physicalMemory < 3_000_000_000
}

// MARK: Réglages lus sans obligation (le verre des boutons fonctionne aussi hors de l'app)

private struct OptionalAppSettingsKey: EnvironmentKey {
    static let defaultValue: AppSettings? = nil
}

extension EnvironmentValues {
    var optionalAppSettings: AppSettings? {
        get { self[OptionalAppSettingsKey.self] }
        set { self[OptionalAppSettingsKey.self] = newValue }
    }
}

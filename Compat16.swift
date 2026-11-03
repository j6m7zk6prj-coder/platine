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

/// Remplace le défilement « paging » d'iOS 17 : une page par élément, on glisse vers le haut.
/// (Un TabView en mode page, tourné d'un quart de tour : chaque page reste dans SwiftUI,
/// avec la navigation et les réglages de l'app.)
struct VerticalPager<Item: Identifiable, Page: View>: View where Item.ID: Hashable {
    let items: [Item]
    @Binding var selection: Item.ID?
    @ViewBuilder var page: (Item) -> Page

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            TabView(selection: $selection) {
                ForEach(items) { item in
                    page(item)
                        .frame(width: w, height: h)
                        .clipped()
                        .rotationEffect(.degrees(-90))
                        .frame(width: h, height: w)
                        .tag(Optional(item.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(width: h, height: w)
            .rotationEffect(.degrees(90), anchor: .topLeading)
            .offset(x: w)
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

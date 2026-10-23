import SwiftUI
import UIKit

/// Une icône d'app au choix. `iconName` nil = l'icône principale.
struct AppIconChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let iconName: String?
    /// Image d'aperçu incluse dans l'app.
    var preview: String { "Preview-" + id }

    private static let knownTitles = ["Noir": "Noir", "Or": "Disque d’or", "Holo": "Holographique", "Cassette": "Cassette"]
    private static let knownOrder = ["Noir", "Or", "Holo", "Cassette"]

    /// L'icône principale, puis toutes les icônes incluses dans l'app (lues dans son Info.plist),
    /// y compris celles que tu ajoutes au projet sous le nom icon-MonNom.png.
    static let all: [AppIconChoice] = {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let alternates = (icons?["CFBundleAlternateIcons"] as? [String: Any])?.keys.map { $0 } ?? []
        let ids = alternates.compactMap { name -> String? in
            name.hasPrefix("AppIcon-") ? String(name.dropFirst("AppIcon-".count)) : nil
        }
        let sorted = ids.sorted {
            let a = knownOrder.firstIndex(of: $0) ?? Int.max
            let b = knownOrder.firstIndex(of: $1) ?? Int.max
            return a != b ? a < b : $0.localizedStandardCompare($1) == .orderedAscending
        }
        return [AppIconChoice(id: "Platine", title: "Platine", iconName: nil)]
            + sorted.map { AppIconChoice(id: $0, title: knownTitles[$0] ?? $0, iconName: "AppIcon-" + $0) }
    }()
}

/// Réglages → Icône de l'app.
struct AppIconPicker: View {
    @Environment(Library.self) private var library
    @State private var current: String? = UIApplication.shared.alternateIconName
    @State private var changing = false

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(AppIconChoice.all) { choice in
                        let selected = choice.iconName == current
                        Button { select(choice) } label: {
                            VStack(spacing: 8) {
                                iconPreview(choice)
                                    .frame(width: 76, height: 76)
                                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                                            .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white.opacity(0.12)),
                                                          lineWidth: selected ? 3 : 0.5)
                                            .padding(selected ? -5 : 0)
                                    )
                                    .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                                    .scaleEffect(selected ? 1.04 : 1)
                                Text(choice.title)
                                    .font(.footnote.weight(selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle(circle: false))
                        .disabled(changing)
                        .accessibilityLabel("Icône \(choice.title)")
                        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.75), value: current)

                VStack(alignment: .leading, spacing: 8) {
                    Label("Ta propre image", systemImage: "photo.badge.plus")
                        .font(.headline)
                    Text("iOS n’autorise pas une app à prendre n’importe quelle image comme icône : elle doit être incluse dans l’app au moment de la compilation. Pour utiliser ta propre image, ajoute-la au projet sur GitHub sous le nom icon-MonNom.png : elle apparaîtra ici après la mise à jour.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .glass(18)
            }
            .padding(20)
        }
        .navigationTitle("Icône de l’app")
        .navigationBarTitleDisplayMode(.inline)
        .background { AmbientBackground(track: nil, dim: 0.65) }
    }

    @ViewBuilder
    private func iconPreview(_ choice: AppIconChoice) -> some View {
        if let img = UIImage(named: choice.preview) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
                .overlay(Image(systemName: "app.dashed").font(.title).foregroundStyle(.secondary))
        }
    }

    private func select(_ choice: AppIconChoice) {
        guard choice.iconName != current, UIApplication.shared.supportsAlternateIcons else { return }
        changing = true
        UIApplication.shared.setAlternateIconName(choice.iconName) { error in
            Task { @MainActor in
                changing = false
                if error == nil {
                    current = choice.iconName
                } else {
                    library.message = "Impossible de changer l’icône"
                }
            }
        }
    }
}

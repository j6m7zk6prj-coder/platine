import SwiftUI

/// Gestion et affichage des stickers holographiques et personnalisés.
struct StickerStack: View {
    let album: AlbumInfo
    let badges: [AlbumBadge]
    let scale: CGFloat
    
    var body: some View {
        HStack(spacing: 8 * scale) {
            ForEach(badges, id: \.self) { badge in
                StickerBadgeView(badge: badge)
                    .scaleEffect(scale)
            }
        }
    }
}

struct StickerBadgeView: View {
    let badge: AlbumBadge
    
    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [.orange, .yellow, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 44, height: 44)
            Text(badge.symbol)
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
    }
}

struct PlacedStickers: View {
    let album: AlbumInfo
    let badges: [AlbumBadge]
    let size: CGSize
    
    var body: some View {
        ZStack {
            ForEach(badges.indices, id: \.self) { i in
                StickerBadgeView(badge: badges[i])
                    .position(x: size.width - 40 - CGFloat(i * 30), y: 40)
            }
        }
    }
}

struct HoloSheen: View {
    let light: CGFloat
    
    var body: some View {
        LinearGradient(colors: [.white.opacity(0.4), .clear, .white.opacity(0.2)],
                       startPoint: UnitPoint(x: 0 + light, y: 0),
                       endPoint: UnitPoint(x: 1 + light, y: 1))
            .blendMode(.overlay)
            .allowsHitTesting(false)
    }
}

import SwiftUI
import AppKit

/// Images whose total pair count exceeds this threshold receive a small dot indicator
/// in the grid tile. Calibrated against the live library distribution (April 2026):
/// p50=53, p75=63, p90=145 — threshold of 100 marks the top ~14% of images.
/// Note: high pair count signals "pairs with many images", not "high-quality pairs"
/// — the avg composite for hub-image pairs equals the library average. Revisit this
/// threshold after thematic clustering/scoring improvements (backlog #23).
private let kPairCountBadgeThreshold = 100

private let kMuted    = Color(red: 0x25/255.0, green: 0x25/255.0, blue: 0x25/255.0)
private let kLikeFill = Color(red: 0xf4/255.0, green: 0xf4/255.0, blue: 0xf5/255.0)
private let kLikeGlyph = Color(red: 0x0e/255.0, green: 0x0e/255.0, blue: 0x10/255.0)

struct PairTileView: View {

    let pair: DisplayPair
    let onLike: () -> Void
    let onReject: () -> Void
    let onExport: () -> Void
    let onOpen: () -> Void
    var onRemoveFromCollection: (() -> Void)? = nil

    @State private var isHovered = false

    private let tileCornerRadius: CGFloat = 8

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                thumbnailRow   // fills available height (grid pins total tile height)
                metadataStrip
            }
            .background(Color.appCard)
            .clipShape(RoundedRectangle(cornerRadius: tileCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: tileCornerRadius)
                    .strokeBorder(
                        isHovered ? Color.appBorder.opacity(0.8) : Color.appBorder.opacity(0.5),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(isHovered ? 0.4 : 0.2),
                    radius: isHovered ? 12 : 4, y: isHovered ? 4 : 2)

            decisionBadge

            if isHovered {
                hoverActions
                    .transition(.opacity.animation(.easeIn(duration: 0.1)))
            } else if pair.decision == .liked {
                likedButton
            } else if pair.decision == .rejected {
                hiddenButton
            }
        }
        .clipped()   // prevent any child from overflowing the tile bounds
        .onHover { isHovered = $0 }
        .onTapGesture { onOpen() }
        .contextMenu {
            Button("Open in Lightbox") { onOpen() }
            Divider()
            Button(pair.decision == .liked ? "Unlike" : "Favorite") { onLike() }
            Button(pair.decision == .rejected ? "Unhide" : "Hide") { onReject() }
            if let remove = onRemoveFromCollection {
                Divider()
                Button("Remove from Collection", action: remove)
            }
            Divider()
            Button("Export…") { onExport() }
        }
    }

    // MARK: - Thumbnail row

    private var thumbnailRow: some View {
        GeometryReader { geo in
            let imageW = (geo.size.width - 2) / 2   // 2pt gap between the two images
            let imageH = geo.size.height
            HStack(spacing: 2) {
                ThumbnailView(url: pair.thumbnailURLA, fallbackColor: pair.colorA)
                    .frame(width: imageW, height: imageH)
                    .clipped()
                    .overlay(alignment: .bottomLeading) {
                        if pair.pairCountA > kPairCountBadgeThreshold {
                            pairCountDot
                        }
                    }
                ThumbnailView(url: pair.thumbnailURLB, fallbackColor: pair.colorB)
                    .frame(width: imageW, height: imageH)
                    .clipped()
                    .overlay(alignment: .bottomTrailing) {
                        if pair.pairCountB > kPairCountBadgeThreshold {
                            pairCountDot
                        }
                    }
            }
        }
        .frame(height: 120)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: tileCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: tileCornerRadius
            )
        )
    }

    /// Subtle dot indicating this image has more than kPairCountBadgeThreshold pairs.
    /// Signals "many pairings" as an invitation to explore — not a quality marker.
    private var pairCountDot: some View {
        Circle()
            .fill(Color.white.opacity(0.55))
            .frame(width: 6, height: 6)
            .padding(5)
    }

    // MARK: - Metadata strip

    private var metadataStrip: some View {
        HStack(spacing: 4) {
            scorePill("A", value: pair.aestheticScore)
            scorePill("G", value: pair.geometricScore)
            scorePill("T", value: pair.thematicScore)
            Text("·")
                .font(.system(size: 10))
                .foregroundColor(Color.appMutedForeground.opacity(0.6))
            Text(String(format: "%.3f", pair.compositeScore))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color.appMutedForeground)
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
    }

    private func scorePill(_ label: String, value: Float) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
            Text(String(format: "%.2f", value))
                .font(.system(size: 9, design: .monospaced))
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Capsule().fill(Color.appSecondary))
        .foregroundColor(Color.appMutedForeground)
    }

    // MARK: - Decision badge (unused — liked/rejected state expressed via action buttons)

    private var decisionBadge: some View { EmptyView() }

    // MARK: - Hover actions (eye · export · heart, left to right)

    private var hoverActions: some View {
        HStack(spacing: 6) {
            TileActionButton(icon: pair.decision == .rejected ? "eye" : "eye.slash",
                             color: kMuted, action: onReject)
            TileActionButton(icon: "square.and.arrow.up",
                             color: kMuted, action: onExport)
            TileActionButton(icon: "heart.fill",
                             color: kLikeFill, iconColor: kLikeGlyph, action: onLike)
        }
        .padding(8)
    }

    // MARK: - Persistent decision buttons (visible in resting state, not on hover)

    private var likedButton: some View {
        TileActionButton(icon: "heart.fill", color: kLikeFill, iconColor: kLikeGlyph, action: onLike)
            .padding(8)
    }

    private var hiddenButton: some View {
        TileActionButton(icon: "eye.slash.fill", color: kLikeFill, iconColor: kLikeGlyph, action: onReject)
            .padding(8)
    }
}

// MARK: - Tile Action Button

private struct TileActionButton: View {
    let icon: String
    let color: Color
    var iconColor: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12)).foregroundColor(iconColor)
                .padding(6)
                .background(Circle().fill(color))
        }
        .buttonStyle(.plain)
    }
}

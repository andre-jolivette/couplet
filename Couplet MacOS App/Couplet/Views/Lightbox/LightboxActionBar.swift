import SwiftUI

struct LightboxActionBar: View {

    let pair: DisplayPair
    let onLike: () -> Void
    let onReject: () -> Void
    let onDelete: () -> Void
    let onAddToCollection: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Spacer()

            actionButton(
                icon: pair.decision == .liked ? "heart.fill" : "heart",
                label: "L",
                color: .pink,
                filled: pair.decision == .liked,
                action: onLike
            )
            actionButton(
                icon: "eye.slash",
                label: "X",
                color: .orange,
                filled: pair.decision == .rejected,
                action: onReject
            )
            actionButton(
                icon: "trash",
                label: "⌫",
                color: .red.opacity(0.8),
                filled: false,
                action: onDelete
            )

            Divider()
                .frame(height: 24)
                .opacity(0.3)

            // Add to collection
            Button(action: onAddToCollection) {
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 13))
                    Text("Add to Collection")
                        .font(.system(size: 12))
                    Text("⌘A")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                }
                .foregroundColor(.white.opacity(0.75))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white.opacity(0.1))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func actionButton(
        icon: String,
        label: String,
        color: Color,
        filled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundColor(filled ? color : .white.opacity(0.75))
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
            }
            .frame(minWidth: 44, minHeight: 36)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(filled ? color.opacity(0.2) : Color.white.opacity(0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

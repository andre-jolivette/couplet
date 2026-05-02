import SwiftUI

struct LightboxTopBar: View {

    let vm: LightboxViewModel
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Back button + breadcrumb
            Button(action: onDismiss) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text(vm.isAnchored ? "Pairs \u{203A} \(vm.anchorFilename ?? "")" : "Pairs")
                        .font(.system(size: 13))
                        .lineLimit(1)
                }
                .foregroundColor(.white.opacity(0.85))
                .padding(.vertical, 8)
                .padding(.trailing, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Pair index
            if vm.pairCount > 0 {
                Text("Pair \(vm.currentIndex + 1) of \(vm.pairCount)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
            }

            Spacer()

            // Modality badge + confidence
            if let pair = vm.currentPair {
                HStack(spacing: 8) {
                    Text(pair.modality.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color(nsColor: pair.modality.color).opacity(0.3))
                        )
                        .foregroundColor(Color(nsColor: pair.modality.color))

                    Text(String(format: "%.3f", pair.compositeScore))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.7), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

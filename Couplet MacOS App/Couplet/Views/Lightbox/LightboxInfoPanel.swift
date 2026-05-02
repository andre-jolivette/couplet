import SwiftUI

struct LightboxInfoPanel: View {

    let pair: DisplayPair
    let isPinned: Bool
    let onTogglePin: () -> Void

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Rationale strip
            HStack {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                Text(pair.rationale)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(2)
                Spacer()
                // Pin toggle
                Button(action: onTogglePin) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .foregroundColor(isPinned ? .yellow : .white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Unpin info panel" : "Pin info panel open (I)")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider().opacity(0.2)

            // Two-column metadata
            HStack(alignment: .top, spacing: 0) {
                imageMetadata(
                    filename: pair.filenameA,
                    folder: pair.folderA,
                    date: pair.captureDateA,
                    scores: (pair.aestheticScore, pair.geometricScore, pair.thematicScore)
                )

                Divider().opacity(0.2)

                imageMetadata(
                    filename: pair.filenameB,
                    folder: pair.folderB,
                    date: pair.captureDateB,
                    scores: nil
                )
            }
        }
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func imageMetadata(
        filename: String,
        folder: String,
        date: Date?,
        scores: (Float, Float, Float)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(filename)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
            Label(folder, systemImage: "folder")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
            if let date {
                Label(dateFormatter.string(from: date), systemImage: "calendar")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }
            if let (a, g, t) = scores {
                Spacer().frame(height: 4)
                HStack(spacing: 10) {
                    scoreChip(label: "A", value: a, color: PairingModality.aesthetic.color)
                    scoreChip(label: "G", value: g, color: PairingModality.geometric.color)
                    scoreChip(label: "T", value: t, color: PairingModality.thematic.color)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scoreChip(label: String, value: Float, color: NSColor) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(nsColor: color).opacity(0.8))
            Text(String(format: "%.2f", value))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
        }
    }
}

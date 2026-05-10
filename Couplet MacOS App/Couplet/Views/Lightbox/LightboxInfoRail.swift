import SwiftUI
import ConjunctEngine

/// Slide-in right rail showing full scoring breakdown for the current pair.
/// Opened by clicking the score block in the top bar.
struct LightboxInfoRail: View {

    let pair: DisplayPair
    static let width: CGFloat = 270

    @State private var captionAExpanded = false
    @State private var captionBExpanded = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                scoreSection(
                    label: "Aesthetic", letter: "A",
                    score: pair.aestheticScore,
                    color: PairingModality.aesthetic.swiftColor,
                    detail: aestheticDetail
                )
                Divider().opacity(0.2).padding(.vertical, 8)
                scoreSection(
                    label: "Geometric", letter: "G",
                    score: pair.geometricScore,
                    color: PairingModality.geometric.swiftColor,
                    detail: geometricDetail
                )
                Divider().opacity(0.2).padding(.vertical, 8)
                scoreSection(
                    label: "Thematic", letter: "T",
                    score: pair.thematicScore,
                    color: PairingModality.thematic.swiftColor,
                    detail: thematicDetail
                )
                Divider().opacity(0.2).padding(.vertical, 8)
                compositeDetail
                Divider().opacity(0.2).padding(.vertical, 8)
                captionsSection
            }
            .padding(16)
            .textSelection(.enabled)
        }
        .background(Color(white: 0.10))
        .frame(width: Self.width)
    }

    // MARK: - Captions

    private var captionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("Captions")
            captionBlock(filename: pair.filenameA, caption: pair.captionA,
                         isExpanded: $captionAExpanded)
            captionBlock(filename: pair.filenameB, caption: pair.captionB,
                         isExpanded: $captionBExpanded)
        }
    }

    private func captionBlock(filename: String, caption: String,
                               isExpanded: Binding<Bool>) -> some View {
        let displayCaption = caption.strippingCaptionOpener()
        // Only show the toggle for captions long enough to overflow 7 lines
        // (~40 chars/line × 7 lines in the 250px card interior).
        let needsToggle = displayCaption.count > 280

        return VStack(alignment: .leading, spacing: 4) {
            Text(filename)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.40))
                .lineLimit(1).truncationMode(.middle)
            if caption.isEmpty {
                Text("No caption available")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.30))
                    .italic()
            } else {
                Text(displayCaption)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.70))
                    .lineLimit(isExpanded.wrappedValue ? nil : 7)
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay(alignment: .bottom) {
                        if !isExpanded.wrappedValue && needsToggle {
                            LinearGradient(
                                colors: [.clear, Color(white: 0.14)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 18)
                            .allowsHitTesting(false)
                        }
                    }
                if needsToggle {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.wrappedValue.toggle()
                        }
                    } label: {
                        Text(isExpanded.wrappedValue ? "Show less" : "Show more")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
    }

    // MARK: - Score sections

    private func scoreSection(
        label: String, letter: String, score: Float, color: Color, detail: some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(letter)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(color)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(color.opacity(0.20)))
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.80))
                Spacer()
                Text(String(format: "%.3f", score))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(color)
            }
            scoreBar(value: score, color: color)
            detail
        }
    }

    private func scoreBar(value: Float, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: geo.size.width * CGFloat(value), height: 4)
            }
        }
        .frame(height: 4)
    }

    // MARK: - Aesthetic detail

    @ViewBuilder
    private var aestheticDetail: some View {
        let submode = pair.aestheticSubmode
        if submode == "accent_echo" {
            accentEchoDetail
        } else {
            let isHarmony = submode == "harmony"
            let description = isHarmony
                ? "Both images share a similar tonal register — similar hue distribution, brightness, and overall colour mood."
                : "The images form a complementary colour relationship — their palettes contrast in a visually resonant way."
            VStack(alignment: .leading, spacing: 4) {
                Text(isHarmony ? "Tonal harmony" : "Colour contrast")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.60))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accentEchoDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Color echo")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.60))
            HStack(alignment: .top, spacing: 8) {
                HStack(spacing: 4) {
                    if let hA = pair.accentHueA {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(hue: hA / 360, saturation: 1.0, brightness: 0.85))
                            .frame(width: 12, height: 12)
                    }
                    if let hB = pair.accentHueB {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(hue: hB / 360, saturation: 1.0, brightness: 0.85))
                            .frame(width: 12, height: 12)
                    }
                }
                .padding(.top, 1)
                Text("Both images share a specific accent colour while diverging in overall palette.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Geometric detail

    private var geometricDetail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Compositional structure")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.60))
            Text("Edge orientation and composition grid similarity. High scores indicate similar framing, subject placement, and visual weight distribution.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Thematic detail

    private var thematicDetail: some View {
        let cA = pair.captionA.isEmpty ? Set<String>() : ConjunctConceptClusters.matchedClusters(for: pair.captionA)
        let cB = pair.captionB.isEmpty ? Set<String>() : ConjunctConceptClusters.matchedClusters(for: pair.captionB)
        let shared = cA.intersection(cB)
        let onlyA = cA.subtracting(cB)
        let onlyB = cB.subtracting(cA)
        let eitherHasCaption = !pair.captionA.isEmpty || !pair.captionB.isEmpty

        return VStack(alignment: .leading, spacing: 8) {
            if !eitherHasCaption {
                Text("No captions available — re-index with moondream to enable thematic analysis.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .italic()
            } else {
                if !pair.captionA.isEmpty && !pair.captionB.isEmpty {
                    // Both captioned — show full cluster breakdown
                    if !shared.isEmpty {
                        clusterRow(label: "Shared concepts", clusters: shared,
                                   color: PairingModality.thematic.swiftColor)
                    }
                    clusterRow(label: "\(pair.filenameA) only", clusters: onlyA,
                               color: .white.opacity(0.50))
                    clusterRow(label: "\(pair.filenameB) only", clusters: onlyB,
                               color: .white.opacity(0.50))
                    if shared.isEmpty {
                        Text("No shared concept clusters — thematic score driven by CLIP embedding similarity.")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.35))
                            .italic()
                    }
                } else {
                    // Partial — show whichever cluster data we have
                    if !cA.isEmpty {
                        clusterRow(label: pair.filenameA, clusters: cA,
                                   color: PairingModality.thematic.swiftColor)
                    }
                    if !cB.isEmpty {
                        clusterRow(label: pair.filenameB, clusters: cB,
                                   color: PairingModality.thematic.swiftColor)
                    }
                    Text("One image not yet captioned — re-index to complete thematic analysis.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                        .italic()
                }
            }
        }
    }

    private func clusterRow(label: String, clusters: Set<String>, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.40))
                .lineLimit(1).truncationMode(.middle)
            if clusters.isEmpty {
                Text("(none)")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.25))
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(clusters.sorted(), id: \.self) { cluster in
                        Text(cluster.replacingOccurrences(of: "_", with: " "))
                            .font(.system(size: 10))
                            .foregroundColor(color)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(color.opacity(0.12)))
                    }
                }
            }
        }
    }

    // MARK: - Composite detail

    private var compositeDetail: some View {
        let scores: [(String, Float, Color)] = [
            ("Aesthetic ×0.40", pair.aestheticScore * 0.40, PairingModality.aesthetic.swiftColor),
            ("Geometric ×0.20", pair.geometricScore * 0.20, PairingModality.geometric.swiftColor),
            ("Thematic ×0.40",  pair.thematicScore  * 0.40, PairingModality.thematic.swiftColor),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            label("Composite")
            ForEach(scores, id: \.0) { name, contribution, color in
                HStack {
                    Text(name)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.50))
                    Spacer()
                    Text(String(format: "+%.3f", contribution))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(color)
                }
            }
            Divider().opacity(0.2)
            HStack {
                Text("Total")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.70))
                Spacer()
                Text(String(format: "%.3f", pair.compositeScore))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }
        }
    }

    // MARK: - Helpers

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.white.opacity(0.30))
            .tracking(1.0)
    }
}

// MARK: - Simple flow layout for cluster chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 200
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxW && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            rowH = max(rowH, size.height)
            x += size.width + spacing
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let _ = bounds.width
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowH = max(rowH, size.height)
            x += size.width + spacing
        }
    }
}

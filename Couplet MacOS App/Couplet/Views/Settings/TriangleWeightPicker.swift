import SwiftUI

// MARK: - TriangleWeightPicker
//
// A triangular control for editing three weights that always sum to 1.0.
// Each vertex represents one scoring modality: Aesthetic (top), Geometric
// (bottom-left), Thematic (bottom-right). The indicator's barycentric
// position encodes the weights. Dragging outside the triangle clamps to
// the nearest edge or vertex.
//
// Usage:
//   TriangleWeightPicker(aesthetic: $aestheticWeight,
//                        geometric: $geometricWeight,
//                        thematic:  $thematicWeight)
//
// Bindings expect Double so they wire directly to @AppStorage properties.
// The scorer expects Float; cast at the call site: Float(aestheticWeight).

struct TriangleWeightPicker: View {

    @Binding var aesthetic: Double
    @Binding var geometric: Double
    @Binding var thematic:  Double

    // Canvas is square; labels live in the padding zone around the inner triangle.
    private let canvasSize: CGFloat = 272
    private let edgePadding: CGFloat = 36   // inset so vertex dots don't clip

    // MARK: Geometry

    /// Equilateral triangle vertices in canvas-local coordinates.
    /// aesthetic = apex (top-centre), geometric = bottom-left, thematic = bottom-right.
    private var verts: (a: CGPoint, g: CGPoint, t: CGPoint) {
        let inner  = canvasSize - 2 * edgePadding
        let height = inner * sqrt(3.0) / 2.0
        let cx     = canvasSize / 2
        let topY   = (canvasSize - height) / 2
        return (
            a: CGPoint(x: cx,              y: topY),
            g: CGPoint(x: cx - inner / 2,  y: topY + height),
            t: CGPoint(x: cx + inner / 2,  y: topY + height)
        )
    }

    /// Canvas position that corresponds to the current weights.
    private var indicatorPosition: CGPoint {
        let v = verts
        return CGPoint(
            x: aesthetic * v.a.x + geometric * v.g.x + thematic * v.t.x,
            y: aesthetic * v.a.y + geometric * v.g.y + thematic * v.t.y
        )
    }

    // MARK: Interaction

    /// Convert a drag location to barycentric weights.
    /// Points outside the triangle clamp to the nearest edge via negative-
    /// coord zeroing; re-normalisation restores the sum-to-1 invariant.
    private func updateWeights(from point: CGPoint) {
        let v = verts
        let denom = (v.g.y - v.t.y) * (v.a.x - v.t.x)
                  + (v.t.x - v.g.x) * (v.a.y - v.t.y)
        guard abs(denom) > 1e-6 else { return }

        let rawA = ((v.g.y - v.t.y) * (point.x - v.t.x)
                  + (v.t.x - v.g.x) * (point.y - v.t.y)) / denom
        let rawG = ((v.t.y - v.a.y) * (point.x - v.t.x)
                  + (v.a.x - v.t.x) * (point.y - v.t.y)) / denom
        let rawT = 1.0 - rawA - rawG

        let ca = max(0, rawA)
        let cg = max(0, rawG)
        let ct = max(0, rawT)
        let sum = ca + cg + ct
        guard sum > 1e-6 else { return }

        aesthetic = ca / sum
        geometric = cg / sum
        thematic  = ct / sum
    }

    // MARK: View

    var body: some View {
        VStack(spacing: 18) {
            triangleCanvas
            resetButton
            weightReadout
        }
    }

    // MARK: Sub-views

    private var triangleCanvas: some View {
        ZStack {
            // Triangle fill + outline + centroid guide lines
            Canvas { ctx, _ in
                let v = verts
                var outline = Path()
                outline.move(to: v.a)
                outline.addLine(to: v.g)
                outline.addLine(to: v.t)
                outline.closeSubpath()

                ctx.fill(outline, with: .color(Color.primary.opacity(0.04)))
                ctx.stroke(outline,
                           with: .color(Color.primary.opacity(0.22)),
                           lineWidth: 1.5)

                // Faint medians help the user read the space
                let centroid = CGPoint(
                    x: (v.a.x + v.g.x + v.t.x) / 3,
                    y: (v.a.y + v.g.y + v.t.y) / 3
                )
                for vertex in [v.a, v.g, v.t] {
                    var median = Path()
                    median.move(to: vertex)
                    median.addLine(to: centroid)
                    ctx.stroke(median,
                               with: .color(Color.primary.opacity(0.07)),
                               lineWidth: 1)
                }
            }
            .frame(width: canvasSize, height: canvasSize)

            // Vertex labels — colours match the app's score-pill convention
            let v = verts
            Text("Aesthetic")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(Color.blue)
                .position(x: v.a.x, y: v.a.y - 17)

            Text("Geometric")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(Color.green)
                .position(x: v.g.x - 28, y: v.g.y + 17)

            Text("Thematic")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(Color.orange)
                .position(x: v.t.x + 26, y: v.t.y + 17)

            // Draggable indicator
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: 16, height: 16)
                .overlay(
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                )
                .position(indicatorPosition)
                .allowsHitTesting(false)   // gestures are handled by the canvas layer
        }
        .frame(width: canvasSize, height: canvasSize)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { updateWeights(from: $0.location) }
        )
    }

    private var weightReadout: some View {
        HStack(spacing: 0) {
            weightBadge(label: "Aesthetic", value: aesthetic, color: .blue)
            Spacer()
            weightBadge(label: "Geometric", value: geometric, color: .green)
            Spacer()
            weightBadge(label: "Thematic",  value: thematic,  color: .orange)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func weightBadge(label: String, value: Double, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(String(format: "%.2f", value))
                .font(.system(.title3, design: .monospaced).weight(.medium))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 82)
    }

    private var resetButton: some View {
        Button("Reset to defaults") {
            withAnimation(.easeInOut(duration: 0.2)) {
                aesthetic = 0.40
                geometric = 0.20
                thematic  = 0.40
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }
}

// MARK: - Preview

#Preview("TriangleWeightPicker") {
    struct Wrapper: View {
        @State private var a: Double = 0.40
        @State private var g: Double = 0.20
        @State private var t: Double = 0.40
        var body: some View {
            TriangleWeightPicker(aesthetic: $a, geometric: $g, thematic: $t)
                .padding(28)
                .frame(width: 360)
        }
    }
    return Wrapper()
}

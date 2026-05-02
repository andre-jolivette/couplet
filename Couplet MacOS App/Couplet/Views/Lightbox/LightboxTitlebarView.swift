import SwiftUI

/// Rendered inside a PassthroughHostingView injected directly into NSTitlebarView
/// when the lightbox is open. Mirrors the layout of LightboxView.topBar but sized
/// for the ~50px titlebar band rather than SwiftUI content space.
///
/// Leading padding of 70pt gives ~(-6)pt of breathing room after the traffic lights (~76px).
/// The back button fills the full titlebar height for a large hit target; the visual
/// highlight is inset vertically so it reads as a floating button, not a full-bleed fill.
struct LightboxTitlebarView: View {
    @ObservedObject var vm: LightboxViewModel
    let onDismiss: () -> Void

    @State private var backHovered = false
    @State private var infoHovered = false

    var body: some View {
        let resting = !vm.controlsVisible
        let fgOpacity: Double    = resting ? 0.25 : 0.85
        let mutedOpacity: Double = resting ? 0.15 : 0.40

        HStack(spacing: 0) {
            // Back button — hit target fills full titlebar height; visual highlight is
            // inset 7pt top/bottom so it reads as a floating rounded button.
            Button(action: onDismiss) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 13, weight: .medium))
                    Text("Pairs")
                        .font(.system(size: 13))
                }
                .foregroundColor(.white.opacity(fgOpacity))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(backHovered && !resting ? 0.08 : 0))
                )
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { backHovered = $0 }

            Spacer()

            if vm.pairCount > 0 {
                Text("Pair \(vm.currentIndex + 1) of \(vm.pairCount)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(mutedOpacity))
            }

            Spacer()

            if let pair = vm.currentPair {
                Button {
                    withAnimation(.easeInOut(duration: 0.20)) { vm.showInfoRail.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        scorePill("A", value: pair.aestheticScore,
                                  color: PairingModality.aesthetic.swiftColor, resting: resting)
                        scorePill("G", value: pair.geometricScore,
                                  color: PairingModality.geometric.swiftColor, resting: resting)
                        scorePill("T", value: pair.thematicScore,
                                  color: PairingModality.thematic.swiftColor, resting: resting)
                        Text(String(format: "%.3f", pair.compositeScore))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(mutedOpacity))
                        Image(systemName: vm.showInfoRail ? "info.circle.fill" : "info.circle")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(resting ? 0.25 : 0.70))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(
                                vm.showInfoRail ? 0.10 : (infoHovered && !resting ? 0.06 : 0)
                            ))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { infoHovered = $0 }
            }
        }
        .padding(.leading, 86)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.25), value: vm.controlsVisible)
    }

    private func scorePill(_ label: String, value: Float, color: Color, resting: Bool) -> some View {
        let opacity: Double = resting ? 0.25 : Double(max(0.35, min(1.0, value)))
        return HStack(spacing: 2) {
            Text(label).font(.system(size: 10, weight: .bold))
            Text(String(format: "%.2f", value)).font(.system(size: 10, design: .monospaced))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(opacity * 0.30)))
        .foregroundColor(color.opacity(opacity))
    }
}

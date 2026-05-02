import SwiftUI

/// Rendered inside a PassthroughHostingView injected directly into NSTitlebarView
/// when the lightbox is open. Mirrors the layout of LightboxView.topBar but sized
/// for the ~50px titlebar band rather than SwiftUI content space.
///
/// Leading padding of 80pt clears the traffic lights (~76px) and the sidebar toggle
/// accessory that remains in the NSTitlebarView subview tree.
struct LightboxTitlebarView: View {
    @ObservedObject var vm: LightboxViewModel
    let onDismiss: () -> Void

    var body: some View {
        let resting = !vm.controlsVisible
        let fgOpacity: Double    = resting ? 0.25 : 0.85
        let mutedOpacity: Double = resting ? 0.15 : 0.40

        HStack(spacing: 12) {
            Button(action: onDismiss) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Pairs")
                        .font(.system(size: 13))
                }
                .foregroundColor(.white.opacity(fgOpacity))
                .frame(minWidth: 60, minHeight: 28)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(vm.showInfoRail ? Color.white.opacity(0.10) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 80)
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

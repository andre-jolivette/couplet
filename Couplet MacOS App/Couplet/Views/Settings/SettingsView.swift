// SettingsView.swift
// Couplet
//
// Presented as the SwiftUI Settings scene (⌘,).
// Exposes runtime-adjustable scoring knobs. No re-index required.
//
// Wire up in your App struct:
//
//   Settings {
//       SettingsView(store: settingsStore)
//   }

import SwiftUI
import ConjunctEngine

struct SettingsView: View {

    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section {
                // ── Modality weights ──────────────────────────────────────
                VStack(alignment: .leading, spacing: 12) {
                    Text("Modality weights")
                        .font(.headline)
                    Text("Drag the handle to redistribute scoring weight across the three modalities. Values always sum to 1.0 and take effect immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Spacer()
                        TriangleWeightPicker(
                            aesthetic: aestheticBinding,
                            geometric: geometricBinding,
                            thematic:  thematicBinding
                        )
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                .padding(.vertical, 6)

            } header: {
                Text("Scoring")
            }

            Section {
                // ── Thematic threshold ────────────────────────────────────
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Minimum thematic score")
                            .font(.headline)
                        Spacer()
                        Text(store.minThematicScore == 0
                             ? "Off"
                             : String(format: "%.2f", store.minThematicScore))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(store.minThematicScore == 0 ? Color.secondary : Color.orange)
                    }

                    Slider(
                        value: $store.minThematicScore,
                        in: 0.0...1.0
                    )
                    .tint(.orange)

                    Text("Pairs below this thematic score are excluded from the grid. At 0.00, no pairs are filtered. Raise to surface only the most thematically resonant matches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)

            } header: {
                Text("Filtering")
            }

            Section {
                // ── Geometric sensitivity ─────────────────────────────────
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Line direction strength")
                            .font(.headline)
                        Spacer()
                        Text(String(format: "%.1f", store.edgePeakednessFloor))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: $store.edgePeakednessFloor,
                        in: 1.0...4.0
                    )
                    .tint(.green)

                    Text("Penalises pairs where neither image has clear directional lines. Circular subjects, crowds, and rough textures produce scattered edges that can match each other by coincidence.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Composition structure floor")
                            .font(.headline)
                        Spacer()
                        Text(String(format: "%.2f", store.gridVarianceFloor))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: $store.gridVarianceFloor,
                        in: 0.0...0.20
                    )
                    .tint(.green)

                    Text("Pairs where neither image has a clear tonal layout score lower geometrically. Raise to require more compositional structure; lower to be more permissive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)

            } header: {
                Text("Geometric Sensitivity")
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Hide sequential pairs", isOn: $store.hideSequential)
                        .font(.headline)
                    Text("Hides pairs of photos captured within 10 seconds of each other. Useful for keeping burst shots and rapid-fire sequences out of the grid.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            } header: {
                Text("Display")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset all to defaults") {
                        withAnimation(.spring(duration: 0.25)) {
                            store.resetAll()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        // Height flexes with content but stays reasonable on small screens
        .frame(minHeight: 720)
        .padding()
    }

    // MARK: - Helpers (weight bindings)

    /// Bridges ScoringWeights Float components to the Double bindings TriangleWeightPicker expects.
    /// All three sets fire in the same run-loop tick during a drag, so intermediate states are
    /// never rendered and the final ScoringWeights is always well-formed.
    private var aestheticBinding: Binding<Double> {
        Binding(
            get: { Double(store.weights.aesthetic) },
            set: { store.weights = ScoringWeights(aesthetic: Float($0), geometric: store.weights.geometric, thematic: store.weights.thematic) }
        )
    }
    private var geometricBinding: Binding<Double> {
        Binding(
            get: { Double(store.weights.geometric) },
            set: { store.weights = ScoringWeights(aesthetic: store.weights.aesthetic, geometric: Float($0), thematic: store.weights.thematic) }
        )
    }
    private var thematicBinding: Binding<Double> {
        Binding(
            get: { Double(store.weights.thematic) },
            set: { store.weights = ScoringWeights(aesthetic: store.weights.aesthetic, geometric: store.weights.geometric, thematic: Float($0)) }
        )
    }

}

// MARK: - Preview

#Preview {
    SettingsView(store: SettingsStore())
}

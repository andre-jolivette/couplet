import SwiftUI

struct FilterBarView: View {

    @ObservedObject var gridVM: PairsGridViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            topRow
            // Second row: submode filters for the selected modality (#109). Only shown
            // when a specific modality chip is active.
            if let modality = gridVM.selectedModality {
                submodeRow(for: modality)
            }
        }
    }

    private var topRow: some View {
        HStack(spacing: 12) {
            // Modality pills — collapses to a dropdown when the window is too narrow
            ViewThatFits(in: .horizontal) {
                modalityPills
                modalityDropdown
            }

            Divider().frame(height: 20)

            // Sort + Tone grouped tightly
            HStack(spacing: -8) {
                Picker("Sort", selection: $gridVM.sortOrder) {
                    ForEach(PairSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
                .padding(.leading, -14)  // compensate NSPopUpButton internal leading inset (~14pt on macOS 14)

                // Color tone filter
                Picker("Tone", selection: $gridVM.colorToneFilter) {
                    Text("All tones").tag(Optional<DisplayPair.ColorTone>.none)
                    ForEach(DisplayPair.ColorTone.allCases, id: \.self) { tone in
                        Text(tone.rawValue).tag(Optional(tone))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 110)
            }

            Divider().frame(height: 20)

            // Show rejected toggle
            Toggle("Show hidden", isOn: $gridVM.showRejected)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundColor(Color.appMutedForeground)
                .fixedSize()

            // Clear filters button
            if gridVM.hasActiveFilters {
                ClearFiltersButton { gridVM.clearFilters() }
            }

            Spacer(minLength: 0)

            // Search — right-aligned
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Color.appMutedForeground)
                    .font(.caption)
                TextField("Search\u{2026}", text: $gridVM.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(Color.appForeground)
                    .frame(width: 160)
                if !gridVM.searchText.isEmpty {
                    SearchClearButton { gridVM.searchText = "" }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.appSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private var modalityPills: some View {
        HStack(spacing: 6) {
            ModalityPill(label: "All",
                         isSelected: gridVM.selectedModality == nil) {
                gridVM.selectedModality = nil
                gridVM.selectedSubmode = nil
            }
            ForEach(PairingModality.allCases) { modality in
                ModalityPill(
                    label: modality.rawValue,
                    isSelected: gridVM.selectedModality == modality
                ) {
                    gridVM.selectedModality =
                        gridVM.selectedModality == modality ? nil : modality
                    gridVM.selectedSubmode = nil   // submodes are modality-specific
                }
            }
        }
    }

    // Submode filters per modality (#109). Keys match the stored submode / relationship
    // values; "directed_gaze" triggers the VM's dedicated uncapped gaze load.
    private func submodes(for modality: PairingModality) -> [(key: String, label: String)] {
        switch modality {
        case .aesthetic:
            return [("accent_echo", "Color echo"), ("harmony", "Tonal harmony"), ("contrast", "Colour contrast")]
        case .geometric:
            return [("directed_gaze", "Directed gaze"), ("gaze_conversation", "Eyes in conversation"),
                    ("opposing_diagonals", "Diagonal tension"), ("directional_complement", "Spatial tension")]
        case .thematic:
            return [("complementary", "Complementary"), ("contrastive", "Contrastive"),
                    ("echo", "Echo"), ("ironic", "Ironic"), ("tonal", "Tonal")]
        }
    }

    private func submodeRow(for modality: PairingModality) -> some View {
        HStack(spacing: 6) {
            ModalityPill(label: "All \(modality.rawValue)", isSelected: gridVM.selectedSubmode == nil) {
                gridVM.selectedSubmode = nil
            }
            ForEach(submodes(for: modality), id: \.key) { sub in
                ModalityPill(label: sub.label, isSelected: gridVM.selectedSubmode == sub.key) {
                    gridVM.selectedSubmode = gridVM.selectedSubmode == sub.key ? nil : sub.key
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 2)
    }

    private var modalityDropdown: some View {
        Picker("Filter", selection: $gridVM.selectedModality) {
            Text("All").tag(Optional<PairingModality>.none)
            ForEach(PairingModality.allCases) { modality in
                Text(modality.rawValue).tag(Optional(modality))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }
}

// MARK: - Modality Pill

private struct ModalityPill: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isSelected
                              ? Color.appPrimary
                              : (hovered ? Color.appSecondary : Color.clear))
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : Color.appBorder, lineWidth: 1)
                )
                .foregroundColor(isSelected
                                 ? Color.appBackground
                                 : (hovered ? Color.appForeground : Color.appMutedForeground))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Clear filters button

private struct ClearFiltersButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text("Clear filters")
                .font(.caption)
                .foregroundColor(hovered ? Color.appForeground : Color.appMutedForeground)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Search clear button

private struct SearchClearButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(hovered ? Color.appForeground : Color.appMutedForeground)
                .font(.caption)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

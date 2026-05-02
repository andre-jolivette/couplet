import SwiftUI

struct FilterBarView: View {

    @ObservedObject var gridVM: PairsGridViewModel

    var body: some View {
        HStack(spacing: 12) {
            // Modality pills
            modalityPills

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
            }
            ForEach(PairingModality.allCases) { modality in
                ModalityPill(
                    label: modality.rawValue,
                    isSelected: gridVM.selectedModality == modality
                ) {
                    gridVM.selectedModality =
                        gridVM.selectedModality == modality ? nil : modality
                }
            }
        }
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

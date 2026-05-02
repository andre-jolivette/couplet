import SwiftUI

struct FilterBarView: View {

    @ObservedObject var gridVM: PairsGridViewModel

    var body: some View {
        HStack(spacing: 12) {
            // Modality pills
            modalityPills

            Divider().frame(height: 20)

            // Sort
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

            Divider().frame(height: 20)

            // Show rejected toggle
            Toggle("Show hidden", isOn: $gridVM.showRejected)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundColor(Color.appMutedForeground)

            // Clear filters button
            if gridVM.hasActiveFilters {
                Button("Clear filters") { gridVM.clearFilters() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(Color.appMutedForeground)
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
                    Button {
                        gridVM.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color.appMutedForeground)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.appSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(Color.appBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.appBorder).frame(height: 1)
        }
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

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.appPrimary : Color.clear)
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : Color.appBorder, lineWidth: 1)
                )
                .foregroundColor(isSelected ? Color.appBackground : Color.appMutedForeground)
        }
        .buttonStyle(.plain)
    }
}

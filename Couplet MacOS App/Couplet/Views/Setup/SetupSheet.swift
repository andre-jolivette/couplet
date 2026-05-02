import SwiftUI
import AppKit

struct SetupSheet: View {

    @EnvironmentObject var engine: EngineController
    @Binding var isPresented: Bool

    @State private var selectedFolderURL: URL? = nil
    @State private var selectedModelURL: URL? = nil

    private var modelAlreadyConfigured: Bool { engine.hasModelBookmark }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {

            VStack(alignment: .leading, spacing: 6) {
                Text("Add Photo Folder")
                    .font(.system(size: 20, weight: .semibold))
                Text("Choose a folder of photos to index.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            // Folder picker
            if let url = selectedFolderURL {
                pickerRow(icon: "folder.fill", primary: url.lastPathComponent,
                          secondary: url.path, changeAction: pickFolder)
            } else {
                emptyPickerButton(icon: "folder.badge.plus",
                                  label: "Choose Photo Folder…", action: pickFolder)
            }

            // Model section — only show if not yet configured
            if !modelAlreadyConfigured {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("CLIP Model")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Optional")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                    if let url = selectedModelURL {
                        pickerRow(icon: "brain", primary: url.lastPathComponent,
                                  secondary: url.path, changeAction: pickModel)
                    } else {
                        emptyPickerButton(icon: "brain",
                                          label: "Locate clip-vit-base-patch32.mlpackage…",
                                          action: pickModel)
                        Text("Without the CLIP model, pairs use colour and geometry only.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }

            HStack {
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.plain).foregroundColor(.secondary)
                Spacer()
                Button("Start Indexing") { startIndexing() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedFolderURL == nil)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func startIndexing() {
        // Only store/rebuild model if user picked a new one
        if let modelURL = selectedModelURL {
            engine.storeModelBookmark(url: modelURL)
        }
        if let folderURL = selectedFolderURL {
            isPresented = false
            engine.addFolder(url: folderURL)
        }
    }

    private func pickerRow(icon: String, primary: String, secondary: String,
                           changeAction: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 18))
                .foregroundColor(.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(primary).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(secondary).font(.system(size: 11)).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Change") { changeAction() }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.accentColor)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func emptyPickerButton(icon: String, label: String,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18))
                    .foregroundColor(.accentColor).frame(width: 28)
                Text(label).font(.system(size: 13)).foregroundColor(.accentColor)
                Spacer()
            }
            .padding(14)
            .background(Color.accentColor.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.25),
                              style: StrokeStyle(lineWidth: 1, dash: [4])))
        }
        .buttonStyle(.plain)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        if panel.runModal() == .OK { selectedFolderURL = panel.url }
    }

    private func pickModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Select Model"
        panel.message = "Locate clip-vit-base-patch32.mlpackage"
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url,
              url.pathExtension == "mlpackage" else { return }
        selectedModelURL = url
    }
}

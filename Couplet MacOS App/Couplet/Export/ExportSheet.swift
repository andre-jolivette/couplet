import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

// MARK: - Format

enum ExportFormat: String, CaseIterable {
    case jpeg = "JPEG"
    case pdf  = "PDF"
}

// MARK: - Sheet

struct ExportSheet: View {

    let pair: DisplayPair
    @EnvironmentObject var engine: EngineController

    @State private var format: ExportFormat = .jpeg
    @State private var includeFilenames: Bool = true
    @State private var isExporting: Bool = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            Text("Export Diptych")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Format")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Picker("Format", selection: $format) {
                    ForEach(ExportFormat.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle("Include filename", isOn: $includeFilenames)
                .font(.system(size: 13))

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    Task { await performExport() }
                } label: {
                    if isExporting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Exporting…")
                        }
                    } else {
                        Text("Export")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isExporting)
            }
        }
        .padding(20)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Export flow

    @MainActor
    private func performExport() async {
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }

        // 1. Resolve full-resolution paths from the engine DB
        guard let (pathA, pathB) = await engine.imagePaths(
            imageAID: pair.imageAID, imageBID: pair.imageBID
        ) else {
            errorMessage = "Could not find source image paths."
            return
        }

        // 2. Acquire security-scoped access to each image's parent folder.
        //    For folders added before bookmark support existed, fall back to an
        //    NSOpenPanel that lets the user re-grant access once — the bookmark is
        //    then stored and subsequent exports work without asking again.
        guard let scopeA = await resolvedScope(for: pathA),
              let scopeB = await resolvedScope(for: pathB)
        else {
            // User cancelled one of the locate-folder panels
            errorMessage = "Folder access was not granted. Export cancelled."
            return
        }

        // 3. Show the save panel
        guard let saveURL = await runSavePanel() else {
            scopeA.stopAccessingSecurityScopedResource()
            scopeB.stopAccessingSecurityScopedResource()
            return
        }

        // 4. Render + write off the main thread.
        //    Security-scoped access remains active for the duration of the task.
        let filenameA = pair.filenameA
        let filenameB = pair.filenameB
        let opts      = DiptychExportOptions(includeFilenames: includeFilenames)
        let useJPEG   = (format == .jpeg)

        do {
            let data: Data? = await Task.detached(priority: .userInitiated) {
                defer {
                    scopeA.stopAccessingSecurityScopedResource()
                    scopeB.stopAccessingSecurityScopedResource()
                }
                guard let cgA = loadCGImage(from: pathA),
                      let cgB = loadCGImage(from: pathB)
                else { return nil }

                let exporter = DiptychExporter(
                    cgImageA: cgA, cgImageB: cgB,
                    filenameA: filenameA, filenameB: filenameB,
                    options: opts
                )
                let result: Data? = useJPEG ? exporter.jpegData() : exporter.pdfData()
                return result
            }.value

            guard let data else {
                errorMessage = "Could not load source images. Files may have been moved or deleted."
                return
            }
            try data.write(to: saveURL)
            dismiss()
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Security scope helpers

    /// Returns a security-scoped folder URL with access already started, or nil if the
    /// user cancels the locate-folder panel. Stores the bookmark for future use.
    @MainActor
    private func resolvedScope(for imagePath: String) async -> URL? {
        // Happy path: bookmark already stored from when the folder was first added
        if let url = engine.startAccessingFolder(for: imagePath) {
            return url
        }

        // Fallback: folder was added before bookmark support — ask the user to locate it
        let folderPath = URL(fileURLWithPath: imagePath)
            .deletingLastPathComponent().path
        guard let url = await locateFolderPanel(expecting: folderPath) else { return nil }

        // Store so we never have to ask again, then start access
        FolderBookmarks.store(url: url)
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    /// Opens an NSOpenPanel asking the user to select the folder at `folderPath`.
    private func locateFolderPanel(expecting folderPath: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Couplet needs access to your photo folder to export.\nPlease select the folder below."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: folderPath)
        return await withCheckedContinuation { cont in
            panel.begin { cont.resume(returning: $0 == .OK ? panel.url : nil) }
        }
    }

    // MARK: - Save panel

    private func runSavePanel() async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .jpeg ? [.jpeg] : [.pdf]
        panel.nameFieldStringValue = suggestedFilename()
        panel.canCreateDirectories = true
        return await withCheckedContinuation { cont in
            panel.begin { cont.resume(returning: $0 == .OK ? panel.url : nil) }
        }
    }

    private func suggestedFilename() -> String {
        let stemA = pair.filenameA.components(separatedBy: ".").dropLast().joined(separator: ".")
        let stemB = pair.filenameB.components(separatedBy: ".").dropLast().joined(separator: ".")
        let base  = [stemA, stemB].filter { !$0.isEmpty }.joined(separator: "-(^_^)-") + "_diptych"
        return base + (format == .jpeg ? ".jpg" : ".pdf")
    }
}

// MARK: - Image loading helper

/// Load a full-resolution CGImage directly from disk using ImageIO.
/// Thread-safe — safe to call from any queue.
private nonisolated func loadCGImage(from path: String) -> CGImage? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

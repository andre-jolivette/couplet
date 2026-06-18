// UninstallResetSheet.swift
// Couplet
//
// Sheet reached from Settings → "Uninstall / Reset Couplet…"
// Handles two related needs with one flow:
//   - Dev reset: wipe DB + caches, relaunch, skip setup (models still present)
//   - Full teardown: wipe DB + caches + models, relaunch into setup flow
// An optional third section (remove Ollama itself) is shown only when Couplet
// knows it installed Ollama during the first-run setup flow (#107).
//
// See decision #107.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ConjunctEngine

// MARK: - Sheet

struct UninstallResetSheet: View {

    let engine: EngineController
    @Environment(\.dismiss) private var dismiss

    @State private var removeModels = true
    @State private var removeOllama = false
    @State private var isResetting = false
    @State private var resetError: String? = nil
    @State private var ollamaAppURL: URL? = nil

    private static let installedOllamaKey = "com.toastbrigade.Couplet.coupletInstalledOllama"
    private var coupletInstalledOllama: Bool {
        UserDefaults.standard.bool(forKey: Self.installedOllamaKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {

            // ── Title ─────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                Text("Uninstall Couplet")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.appPrimary)
                Text("Removes Couplet's database and cached thumbnails. Your original photos are never touched.")
                    .font(.system(size: 13))
                    .foregroundColor(.appMutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // ── Scope checkbox ────────────────────────────────────────────
            CheckRow(
                isOn: $removeModels,
                disabled: false,
                label: "Also remove Ollama models",
                sublabel: "qwen2.5vl-caption and qwen2.5:14b-instruct"
            )

            // ── Ollama-itself section (only when Couplet installed it) ────
            if coupletInstalledOllama {
                Divider()
                ollamaSection
            }

            Divider()

            // ── Error ─────────────────────────────────────────────────────
            if let err = resetError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // ── Action row ────────────────────────────────────────────────
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.appMutedForeground)
                    .disabled(isResetting)

                Spacer()

                Button(action: { Task { await performReset() } }) {
                    if isResetting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini).tint(.white)
                            Text("Uninstalling…")
                        }
                    } else {
                        Text("Uninstall Couplet\u{2026}")
                    }
                }
                .buttonStyle(DestructiveButtonStyle())
                .disabled(isResetting)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Color.appBackground)
        .onAppear {
            if coupletInstalledOllama {
                ollamaAppURL = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: "ai.ollama.ollama"
                )
            }
        }
    }

    // MARK: - Ollama-itself section

    private var ollamaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $removeOllama) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also remove Ollama itself")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.appPrimary)
                    Text("Couplet installed Ollama during setup. These two paths let you remove it.")
                        .font(.system(size: 12))
                        .foregroundColor(.appMutedForeground)
                }
            }
            .toggleStyle(.checkbox)

            if removeOllama {
                VStack(alignment: .leading, spacing: 10) {
                    OllamaRemovalRow(
                        title: "Find and trash Ollama.app",
                        detail: "Quit Ollama from the menu bar first, then use the picker below to move it to the Trash. The Trash is reversible.",
                        action: { openOllamaTrashPanel() },
                        actionLabel: "Open Picker\u{2026}"
                    )

                    OllamaRemovalRow(
                        title: "Homebrew uninstall",
                        detail: "If you installed Ollama via Homebrew, copy this command and run it in Terminal.",
                        action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew uninstall ollama", forType: .string)
                        },
                        actionLabel: "Copy Command"
                    )
                }
                .padding(.leading, 20)
            }
        }
    }

    // MARK: - Reset

    private func performReset() async {
        isResetting = true
        resetError = nil

        // 1. Remove models first (while Ollama is still reachable)
        if removeModels {
            for model in ["qwen2.5vl-caption", "qwen2.5:14b-instruct"] {
                await deleteOllamaModel(model)
            }
        }

        // 2. Shut down the engine — cancels tasks, releases DB pool
        engine.prepareForReset()

        // 3. Delete data files
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches    = fm.urls(for: .cachesDirectory,              in: .userDomainMask)[0]

        let targets: [URL] = [
            appSupport.appendingPathComponent("Conjunct/conjunct.db"),
            caches.appendingPathComponent("Conjunct/thumbnails"),
            caches.appendingPathComponent("Conjunct/previews"),
        ]
        for url in targets {
            try? fm.removeItem(at: url)
        }

        // 4. Clear UserDefaults (all app-scoped keys)
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            UserDefaults.standard.synchronize()
        }

        // 5. Relaunch and exit
        NSWorkspace.shared.open(Bundle.main.bundleURL)
        exit(0)
    }

    // MARK: - Ollama trash panel

    @MainActor
    private func openOllamaTrashPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = ollamaAppURL?.deletingLastPathComponent()
            ?? URL(filePath: "/Applications")
        panel.message = "Select Ollama.app to move it to the Trash. Quit Ollama from the menu bar first."
        panel.prompt = "Move to Trash"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            resetError = "Could not trash \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

// MARK: - Helpers

private struct CheckRow: View {
    @Binding var isOn: Bool
    let disabled: Bool
    let label: String
    let sublabel: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.checkbox)
                .disabled(disabled)
                .labelsHidden()
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(disabled ? .appMutedForeground : .appPrimary)
                Text(sublabel)
                    .font(.system(size: 11))
                    .foregroundColor(.appMutedForeground)
            }
        }
    }
}

private struct OllamaRemovalRow: View {
    let title: String
    let detail: String
    let action: () -> Void
    let actionLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.appPrimary)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(.appMutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(actionLabel, action: action)
                    .buttonStyle(SetupSecondaryButtonStyle())
                    .font(.system(size: 12))
            }
        }
        .padding(12)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
    }
}

struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.red.opacity(configuration.isPressed ? 0.75 : 0.85))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Ollama model deletion

private func deleteOllamaModel(_ model: String) async {
    guard let url = URL(string: "http://127.0.0.1:11434/api/delete") else { return }
    var req = URLRequest(url: url)
    req.httpMethod = "DELETE"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
    let session = URLSession(configuration: .ephemeral)
    _ = try? await session.data(for: req)
    // 404 when model not present → ignored gracefully
}

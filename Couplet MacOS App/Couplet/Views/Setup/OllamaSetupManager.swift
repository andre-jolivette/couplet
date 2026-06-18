import Foundation
import Combine
import ConjunctEngine

// MARK: - Model row state

enum ModelRowPhase: Equatable {
    case waiting
    case downloading(completed: Int64, total: Int64)
    case verifying   // post-download: Ollama checking digest, writing manifest
    case configuring // ollama create (near-instant, post-download)
    case done
    case failed(String)

    var isComplete: Bool { self == .done }
    var isBusy: Bool {
        switch self { case .downloading, .verifying, .configuring: true; default: false }
    }
}

// MARK: - Setup step

enum SetupStep {
    case checkingDependencies
    case installOllama
    case pullingModels
    case done
}

// MARK: - Manager

/// Drives the first-run setup flow: checks Ollama, pulls models, runs `ollama create`.
/// Published properties always update on @MainActor.
@MainActor
final class OllamaSetupManager: ObservableObject {

    @Published var step: SetupStep = .checkingDependencies
    @Published var captionModelPhase: ModelRowPhase = .waiting
    @Published var thematicModelPhase: ModelRowPhase = .waiting

    var allModelsDone: Bool {
        captionModelPhase.isComplete && thematicModelPhase.isComplete
    }

    // MARK: - Entry points

    func checkAndAdvance() {
        Task { await _check() }
    }

    func startModelPull() {
        Task { await _pullAllModels() }
    }

    func retryCaptionModel() {
        Task {
            await _pullCaptionModel()
            if allModelsDone { step = .done }
        }
    }

    func retryThematicModel() {
        Task {
            await _pullThematicModel()
            if allModelsDone { step = .done }
        }
    }

    // MARK: - Dependency check

    private func _check() async {
        step = .checkingDependencies
        let inventory = await OllamaInventory.check()
        guard inventory.reachable else {
            // Set here — when the step is first shown — not after a successful recheck,
            // so the flag survives if the user quits mid-setup. The Uninstall / Reset sheet
            // reads it to decide whether to offer Ollama removal.
            UserDefaults.standard.set(true, forKey: "com.toastbrigade.Couplet.coupletInstalledOllama")
            step = .installOllama
            return
        }
        let needsCaption  = !inventory.has(model: "qwen2.5vl-caption")
        let needsThematic = !inventory.has(model: "qwen2.5:14b-instruct")
        if needsCaption || needsThematic {
            // Only set the step — PullingModelsView.onAppear calls startModelPull().
            // Calling _pullAllModels() here too would double-fire ollamaCreate.
            step = .pullingModels
        } else {
            step = .done
        }
    }

    // MARK: - Pull both models concurrently

    private func _pullAllModels() async {
        step = .pullingModels
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self._pullCaptionModel() }
            group.addTask { await self._pullThematicModel() }
        }
        if allModelsDone { step = .done }
    }

    // MARK: - Caption model (pull qwen2.5vl:7b + ollama create)

    private func _pullCaptionModel() async {
        let inventory = await OllamaInventory.check()
        if inventory.has(model: "qwen2.5vl-caption") {
            captionModelPhase = .done
            return
        }
        // Only pull the base model if it isn't already in Ollama.
        // Ollama's model store lives outside the sandbox and survives app reinstalls,
        // so re-pulling an existing model causes a spurious download flash.
        if !inventory.has(model: "qwen2.5vl:7b") {
            do {
                try await pullOllamaModel(model: "qwen2.5vl:7b") { [weak self] completed, total in
                    if let self, self.captionTotalBytes == 0 { self.captionTotalBytes = total }
                    await self?.setCaptionPhase(.downloading(completed: completed, total: total))
                } onVerifying: { [weak self] in
                    self?.setCaptionPhase(.verifying)
                }
            } catch {
                print("[setup] qwen2.5vl:7b pull failed: \(error)")
                captionModelPhase = .failed(error.localizedDescription)
                return
            }
        }
        print("[setup] qwen2.5vl:7b pull done — calling ollamaCreate")
        captionModelPhase = .configuring
        do {
            try await ollamaCreate(name: "qwen2.5vl-caption")
            captionModelPhase = .done
        } catch {
            print("[setup] ollamaCreate failed: \(error)")
            captionModelPhase = .failed(error.localizedDescription)
        }
    }

    private func setCaptionPhase(_ phase: ModelRowPhase) {
        captionModelPhase = phase
    }

    // MARK: - Thematic model (direct pull)

    private func _pullThematicModel() async {
        let inventory = await OllamaInventory.check()
        if inventory.has(model: "qwen2.5:14b-instruct") {
            thematicModelPhase = .done
            return
        }
        do {
            try await pullOllamaModel(model: "qwen2.5:14b-instruct") { [weak self] completed, total in
                if let self, self.thematicTotalBytes == 0 { self.thematicTotalBytes = total }
                await self?.setThematicPhase(.downloading(completed: completed, total: total))
            } onVerifying: { [weak self] in
                self?.setThematicPhase(.verifying)
            }
            thematicModelPhase = .done
        } catch {
            thematicModelPhase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Real model size (extracted from first pull progress event)

    @Published var captionTotalBytes: Int64 = 0
    @Published var thematicTotalBytes: Int64 = 0

    private func setThematicPhase(_ phase: ModelRowPhase) {
        thematicModelPhase = phase
    }
}

// MARK: - Ollama pull (streaming /api/pull) — nonisolated, no MainActor state

private func pullOllamaModel(
    model: String,
    onProgress: @escaping (Int64, Int64) async -> Void,
    onVerifying: @escaping () async -> Void = {}
) async throws {
    guard let url = URL(string: "http://127.0.0.1:11434/api/pull") else { return }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: ["name": model, "stream": true])

    let session = URLSession(configuration: .ephemeral)
    let (bytes, response) = try await session.bytes(for: req)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw OllamaSetupError.badStatus
    }

    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0

    for try await line in bytes.lines {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }

        let hasCompleted = json["completed"] != nil
        let hasTotal     = json["total"] != nil

        if let c = json["completed"] as? Int64 { completedBytes = c }
        else if let c = json["completed"] as? Int { completedBytes = Int64(c) }
        if let t = json["total"] as? Int64 { totalBytes = t }
        else if let t = json["total"] as? Int { totalBytes = Int64(t) }

        let status = json["status"] as? String ?? ""
        if status == "success" { return }

        if hasCompleted || hasTotal {
            if totalBytes > 0 {
                await onProgress(completedBytes, totalBytes)
            }
        } else if status == "writing manifest" || status == "removing any unused layers" {
            // These appear exactly once, after all layers finish — the real final-stage.
            // "verifying digest" appears after every individual layer and is skipped here
            // to avoid the progress-bar ↔ verifying-spinner stutter on multi-layer models.
            await onVerifying()
        }
    }
}

// MARK: - ollama create (via POST /api/create) — sandbox-safe, no subprocess
// Uses the structured Ollama API (from + parameters) rather than a raw Modelfile string.
// Older Ollama versions used "modelfile"; newer versions require "from" — this is the current form.

private func ollamaCreate(name: String) async throws {
    guard let url = URL(string: "http://127.0.0.1:11434/api/create") else { return }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": name,
        "from": "qwen2.5vl:7b",
        "parameters": ["num_ctx": 2048],
        "stream": false
    ])
    let session = URLSession(configuration: .ephemeral)
    let (data, response) = try await session.data(for: req)
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    print("[ollamaCreate] HTTP \(statusCode), body: \(String(data: data, encoding: .utf8) ?? "")")
    guard statusCode == 200 else {
        let ollamaError = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0["error"] as? String }
            ?? "HTTP \(statusCode)"
        throw OllamaSetupError.createFailed(ollamaError)
    }
}

// MARK: - Errors

enum OllamaSetupError: LocalizedError {
    case badStatus
    case modelfileNotFound
    case createFailed(String) // raw Ollama error — shown only in debug print; UI uses plain message below

    var errorDescription: String? {
        switch self {
        case .badStatus:
            return "Couldn't reach Ollama. Make sure it's running and try again."
        case .modelfileNotFound:
            return "Modelfile not found in app bundle."
        case .createFailed:
            return "Couldn't configure the caption model. Quit Ollama from the menu bar, reopen it, then retry."
        }
    }
}

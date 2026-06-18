import Foundation
import Combine
import ConjunctEngine

// MARK: - Model row state

enum ModelRowPhase: Equatable {
    case waiting
    case downloading(completed: Int64, total: Int64)
    case configuring  // ollama create (near-instant, post-download)
    case done
    case failed(String)

    var isComplete: Bool { self == .done }
    var isBusy: Bool {
        switch self { case .downloading, .configuring: true; default: false }
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
        Task { await _pullCaptionModel() }
    }

    func retryThematicModel() {
        Task { await _pullThematicModel() }
    }

    // MARK: - Dependency check

    private func _check() async {
        step = .checkingDependencies
        let inventory = await OllamaInventory.check()
        guard inventory.reachable else {
            // Record that the setup flow showed the install step — used by the
            // Uninstall / Reset sheet to know whether to offer Ollama removal.
            UserDefaults.standard.set(true, forKey: "com.toastbrigade.Couplet.coupletInstalledOllama")
            step = .installOllama
            return
        }
        let needsCaption  = !inventory.has(model: "qwen2.5vl-caption")
        let needsThematic = !inventory.has(model: "qwen2.5:14b-instruct")
        if needsCaption || needsThematic {
            step = .pullingModels
            await _pullAllModels()
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
    }

    // MARK: - Caption model (pull qwen2.5vl:7b + ollama create)

    private func _pullCaptionModel() async {
        let inventory = await OllamaInventory.check()
        if inventory.has(model: "qwen2.5vl-caption") {
            captionModelPhase = .done
            return
        }
        do {
            try await pullOllamaModel(model: "qwen2.5vl:7b") { [weak self] completed, total in
                await self?.setCaptionPhase(.downloading(completed: completed, total: total))
            }
        } catch {
            captionModelPhase = .failed(error.localizedDescription)
            return
        }
        captionModelPhase = .configuring
        do {
            try await ollamaCreate(name: "qwen2.5vl-caption")
            captionModelPhase = .done
        } catch {
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
                await self?.setThematicPhase(.downloading(completed: completed, total: total))
            }
            thematicModelPhase = .done
        } catch {
            thematicModelPhase = .failed(error.localizedDescription)
        }
    }

    private func setThematicPhase(_ phase: ModelRowPhase) {
        thematicModelPhase = phase
    }
}

// MARK: - Ollama pull (streaming /api/pull) — nonisolated, no MainActor state

private func pullOllamaModel(
    model: String,
    onProgress: @escaping (Int64, Int64) async -> Void
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

        if let c = json["completed"] as? Int64 { completedBytes = c }
        else if let c = json["completed"] as? Int { completedBytes = Int64(c) }
        if let t = json["total"] as? Int64 { totalBytes = t }
        else if let t = json["total"] as? Int { totalBytes = Int64(t) }

        if totalBytes > 0 {
            await onProgress(completedBytes, totalBytes)
        }
        if (json["status"] as? String) == "success" { return }
    }
}

// MARK: - ollama create (via bundled Modelfile) — nonisolated

private func ollamaCreate(name: String) async throws {
    guard let modelfileURL = Bundle.main.url(forResource: "Modelfile", withExtension: nil) else {
        throw OllamaSetupError.modelfileNotFound
    }
    let modelfilePath = modelfileURL.path

    return try await withCheckedThrowingContinuation { continuation in
        func run(executablePath: String, onFailure: @escaping () -> Void) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executablePath)
            proc.arguments = ["create", name, "-f", modelfilePath]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError  = FileHandle.nullDevice
            proc.terminationHandler = { p in
                if p.terminationStatus == 0 { continuation.resume() }
                else { onFailure() }
            }
            guard (try? proc.run()) != nil else { onFailure(); return }
        }
        run(executablePath: "/usr/local/bin/ollama") {
            run(executablePath: "/opt/homebrew/bin/ollama") {
                continuation.resume(throwing: OllamaSetupError.createFailed(name))
            }
        }
    }
}

// MARK: - Errors

enum OllamaSetupError: LocalizedError {
    case badStatus
    case modelfileNotFound
    case createFailed(String)

    var errorDescription: String? {
        switch self {
        case .badStatus:           return "Ollama returned an unexpected status."
        case .modelfileNotFound:   return "Modelfile not found in app bundle."
        case .createFailed(let n): return "Failed to create model '\(n)'."
        }
    }
}

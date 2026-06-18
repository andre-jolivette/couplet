import Foundation

// MARK: - Ollama inventory

/// Single GET /api/tags call. Returns reachability and the set of installed model name prefixes.
/// Distinct from the individual isAvailable() methods on each engine — this is a one-shot
/// check that powers the UI health indicator rather than gating engine construction.
public struct OllamaInventory: Sendable {
    public let reachable: Bool
    public let availableModels: Set<String>

    public static func check(host: String = "http://127.0.0.1:11434") async -> OllamaInventory {
        guard let url = URL(string: "\(host)/api/tags") else {
            return OllamaInventory(reachable: false, availableModels: [])
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5   // fast probe — if Ollama is running it responds in <1s
        let session = URLSession(configuration: config)
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return OllamaInventory(reachable: false, availableModels: [])
        }
        let names = Set(models.compactMap { $0["name"] as? String })
        return OllamaInventory(reachable: true, availableModels: names)
    }

    public func has(model: String) -> Bool {
        availableModels.contains { $0.hasPrefix(model) }
    }
}

// MARK: - CLIP status

public enum CLIPStatus: Equatable, Sendable {
    /// Fresh install — no bookmark stored. Not a failure state; the setup flow handles it.
    case notConfigured
    /// Bookmark exists and the model loaded successfully.
    case healthy
    /// Bookmark was previously stored but the model can no longer be accessed.
    case broken
}

// MARK: - Issue model

public struct DependencyIssue: Equatable, Identifiable, Sendable {
    public var id: String { title }
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

// MARK: - Health aggregate

public struct DependencyHealth: Equatable, Sendable {
    public let issues: [DependencyIssue]
    public var isHealthy: Bool { issues.isEmpty }

    public init(issues: [DependencyIssue]) {
        self.issues = issues
    }

    public static let healthy = DependencyHealth(issues: [])
}

// MARK: - Issue construction

/// Required Ollama model names and the feature each gates. Order matters — captions
/// first, then role/thematic (single model covering both).
public let kRequiredOllamaModels: [(name: String, featureLabel: String, installHint: String)] = [
    (
        name: "qwen2.5vl-caption",
        featureLabel: "Caption generation",
        installHint: "ollama pull qwen2.5vl:7b && ollama create qwen2.5vl-caption -f ConjunctEngine/Modelfile"
    ),
    (
        name: "qwen2.5:14b-instruct",
        featureLabel: "Role matching and thematic scoring",
        installHint: "ollama pull qwen2.5:14b-instruct"
    ),
]

/// Pure issue-construction function. All inputs are value types; no actor inference possible.
/// Mirrors the pattern in PairHelpers.swift (decision #41 — nonisolated to avoid @MainActor pullthrough).
public nonisolated func buildDependencyIssues(
    ollamaInventory: OllamaInventory,
    clipStatus: CLIPStatus
) -> [DependencyIssue] {
    var issues: [DependencyIssue] = []

    if !ollamaInventory.reachable {
        issues.append(DependencyIssue(
            title: "Background scoring paused",
            body: "Ollama is not running. Captioning, role matching, and thematic scoring are paused. CLIP embedding, aesthetic, and geometric scoring are unaffected."
        ))
    } else {
        for entry in kRequiredOllamaModels where !ollamaInventory.has(model: entry.name) {
            issues.append(DependencyIssue(
                title: "\(entry.featureLabel) paused",
                body: "Model not installed: \(entry.name). Run: \(entry.installHint)"
            ))
        }
    }

    if clipStatus == .broken {
        issues.append(DependencyIssue(
            title: "CLIP model unavailable",
            body: "The bundled CLIP model failed to load. Reinstalling the app should restore visual feature extraction."
        ))
    }

    return issues
}

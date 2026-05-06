import Foundation

// MARK: - Protocol

/// Generates a dense vector embedding from a caption string.
/// Used to compute caption-level semantic similarity between image pairs.
public protocol CaptionEmbeddingEngine: Sendable {
    func embed(caption: String) async throws -> [Float]
}

// MARK: - Ollama implementation

/// Calls a locally-running ollama server to embed caption text via nomic-embed-text.
/// Run `ollama pull nomic-embed-text` to set it up.
///
/// Returns a 768-dim L2-normalised float vector. Cosine similarity between two such
/// vectors measures semantic proximity — not keyword overlap, but conceptual meaning.
/// This is the primary signal for thematic scoring when caption embeddings are present.
///
/// API: POST /api/embeddings {"model": "nomic-embed-text", "prompt": "<caption>"}
/// Response: {"embedding": [Double, ...]}  (768 values)
public actor OllamaEmbeddingEngine: CaptionEmbeddingEngine {

    private let endpoint: URL
    private let model: String
    // Ephemeral session — no disk cache, prevents URLSession storage warnings
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

    public init(
        host: String = "http://localhost:11434",
        model: String = "nomic-embed-text"
    ) {
        self.endpoint = URL(string: "\(host)/api/embeddings")!
        self.model = model
    }

    public func embed(caption: String) async throws -> [Float] {
        let body: [String: Any] = ["model": model, "prompt": caption]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EmbeddingError.serverError(
                (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embedding = json["embedding"] as? [Double],
              !embedding.isEmpty else {
            throw EmbeddingError.malformedResponse
        }

        return embedding.map(Float.init)
    }

    /// Returns true if the ollama server is reachable and nomic-embed-text is available.
    public static func isAvailable(
        host: String = "http://localhost:11434",
        model: String = "nomic-embed-text"
    ) async -> Bool {
        guard let url = URL(string: "\(host)/api/tags") else { return false }
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return false }
        return models.contains { ($0["name"] as? String)?.hasPrefix(model) == true }
    }

    public enum EmbeddingError: Error, LocalizedError {
        case serverError(Int)
        case malformedResponse

        public var errorDescription: String? {
            switch self {
            case .serverError(let code):
                return "Ollama server returned HTTP \(code). Is nomic-embed-text available? Run: ollama pull nomic-embed-text"
            case .malformedResponse:
                return "Unexpected response format from ollama embeddings API"
            }
        }
    }
}

// MARK: - Stub (no embedding)

/// Used when ollama is not available. Returns an empty array so the thematic
/// scorer falls back to cluster-only scoring.
public struct MockEmbeddingEngine: CaptionEmbeddingEngine, Sendable {
    public init() {}
    public func embed(caption: String) async throws -> [Float] { return [] }
}

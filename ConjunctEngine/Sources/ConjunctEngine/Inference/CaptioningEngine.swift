import Foundation
import CoreGraphics
import ImageIO

// MARK: - Protocol

/// Generates a concise natural-language caption describing what is happening
/// in a photo — subject, action, context — suitable for thematic comparison.
public protocol CaptioningEngine: Sendable {
    func caption(imageURL: URL) async throws -> String
}

// MARK: - Ollama implementation

/// Calls a locally-running ollama server (http://localhost:11434) using the
/// qwen2.5vl-caption model (a trimmed variant of qwen2.5vl:7b registered via
/// ConjunctEngine/Modelfile). Run `ollama pull qwen2.5vl:7b` then
/// `ollama create qwen2.5vl-caption -f ConjunctEngine/Modelfile` to set it up.
///
/// The custom model sets num_ctx 2048 to avoid the default 128k KV cache
/// allocation — see ConjunctEngine/Modelfile for the full rationale.
///
/// Prompt is tuned for thematic indexing: single flowing paragraph covering
/// scene context, social situation, emotional register, symbolism, irony/humour,
/// and meaningful contrasts within the frame.
public actor OllamaCaptioningEngine: CaptioningEngine {

    private let endpoint: URL
    private let model: String
    private let timeoutSeconds: Double
    // Ephemeral session — no disk cache, prevents "Cache storage exceeds limit" spam
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 150   // ceiling; per-request timeout (below) takes precedence
        return URLSession(configuration: config)
    }()

    public init(
        host: String = "http://localhost:11434",
        model: String = "qwen2.5vl-caption",    // custom variant with num_ctx 2048; see ConjunctEngine/Modelfile
        timeoutSeconds: Double = 120             // qwen is 3–6 s/image on M1 Max; cold load needs headroom
    ) {
        self.endpoint = URL(string: "\(host)/api/generate")!
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    public func caption(imageURL: URL) async throws -> String {
        // Resize to 512px before encoding. Full-resolution camera files often
        // encode to 2000+ vision tokens with qwen2.5vl's tiled patch encoding;
        // a 512px thumbnail produces ~250 prompt tokens total — well within the
        // num_ctx 2048 budget set in ConjunctEngine/Modelfile. Falls back to the
        // raw file only if thumbnail generation fails.
        let imageData: Data
        if let thumb = thumbnailData(from: imageURL) {
            imageData = thumb
        } else {
            imageData = try Data(contentsOf: imageURL)
        }
        let b64 = imageData.base64EncodedString()

        let prompt = """
Describe this photograph in a single flowing paragraph — reading it as a careful \
observer would, attending to what the scene means, not just what it contains.

What kind of place or moment is this? Name the social or cultural context if you \
can read it: a ceremony, a protest, a street encounter, a fair, a ritual, a vigil. \
What is the atmosphere — calm, tense, reverent, chaotic, absurd, hollow?

If people are present, describe whether they are actually engaging with one another \
or merely sharing the frame — and attend to the quality of their action, not just \
what they are doing: rushed, deliberate, collapsed inward, numb, graceful, \
aggressive. Describe emotional register with depth: not "looks sad" but the texture \
of it — withdrawn, grief-stricken, quietly devastated, bracing for something, \
unexpectedly tender.

Note any visible symbols — religious, political, commercial, cultural — and \
describe how they sit in relation to the people or context around them. If the \
frame contains humour, irony, or incongruity — a person mirroring a sign behind \
them, something absurdly out of place, unintended comedy — name it. Describe any \
significant contrast in the frame: between moods, between people, between a person \
and their surroundings.

Write in direct observational prose. No preamble, no "The image shows", no mention \
of camera, focus, or image quality. Write in English only.
"""

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "images": [b64],
            "stream": false,
            // num_predict raised 250 → 400 → 500. At 250 tokens (~1,000–1,200 chars),
            // 57% of captions were cut mid-sentence; at 400, ~23% still truncated.
            // 500 tokens ≈ 1,800–2,200 chars — enough for qwen to complete naturally
            // while staying within the num_ctx 2048 budget (prompt ≈ 270 tokens
            // + image ≈ 250 tokens + 500 output = ~1,020 total).
            //
            // repeat_penalty 1.15 prevents the degenerate repetition loops seen in
            // ~8 captions on the 400-token pass (e.g. "the the the the...").
            "options": ["temperature": 0.2, "num_predict": 500, "repeat_penalty": 1.15]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeoutSeconds

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CaptioningError.serverError(
                (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            throw CaptioningError.malformedResponse
        }

        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // qwen2.5vl:7b occasionally leaks tokenizer special tokens into output
        // (e.g. "<|im_start|>", "<|im_end|>") when generation is cut off at the
        // token budget boundary. Truncate at the first such token.
        let specialTokenMarker = "<|im_"
        if let range = cleaned.range(of: specialTokenMarker) {
            cleaned = String(cleaned[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    /// Returns a 512px JPEG-encoded thumbnail of the image at `url`.
    ///
    /// Matches the thumbnail pipeline used by CLIP and the IndexingEngine —
    /// same 512px ceiling, same transform-aware downscale via ImageIO.
    private func thumbnailData(from url: URL, maxDimension: Int = 512) -> Data? {
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        let buf = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            buf as CFMutableData, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, thumb,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buf as Data
    }

    /// Returns true if the ollama server is reachable and qwen2.5vl-caption is available.
    public static func isAvailable(
        host: String = "http://localhost:11434",
        model: String = "qwen2.5vl-caption"
    ) async -> Bool {
        guard let url = URL(string: "\(host)/api/tags") else { return false }
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return false }
        return models.contains { ($0["name"] as? String)?.hasPrefix(model) == true }
    }

    public enum CaptioningError: Error, LocalizedError {
        case serverError(Int)
        case malformedResponse

        public var errorDescription: String? {
            switch self {
            case .serverError(let code):
                return "Ollama server returned HTTP \(code). Is qwen2.5vl-caption registered? Run: ollama pull qwen2.5vl:7b && ollama create qwen2.5vl-caption -f ConjunctEngine/Modelfile"
            case .malformedResponse:
                return "Unexpected response format from ollama"
            }
        }
    }
}

// MARK: - Stub (no captioning)

/// Used when ollama is not available. Returns empty string so the thematic
/// scorer falls back to CLIP embedding similarity.
public struct MockCaptioningEngine: CaptioningEngine, Sendable {
    public init() {}
    public func caption(imageURL: URL) async throws -> String { return "" }
}

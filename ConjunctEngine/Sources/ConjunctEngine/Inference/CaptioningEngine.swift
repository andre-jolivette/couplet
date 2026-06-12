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
/// Prompt is tuned for thematic indexing (#50 v2): physical facts first (hands,
/// feet, gaze target, precise objects, apparent gender), then direction of every
/// significant action, then emotional register — every emotional word tied to a
/// named visible detail. Generic mood phrases ("quiet introspection") are banned;
/// they turned images into scoring hubs in ThematicV2 (see decision #97).
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
        // Resize to 768px before encoding. Full-resolution camera files often
        // encode to 2000+ vision tokens with qwen2.5vl's tiled patch encoding;
        // a 768px max-dimension thumbnail produces ~500–750 image tokens.
        // Budget check against num_ctx 2048 (ConjunctEngine/Modelfile):
        // image ≤750 + prompt ≈460 + output 500 ≈ 1,710. Raised from 512px in
        // #50/#97 — at 512px qwen missed small load-bearing details (a rose in
        // a cup read as a "red bandana"). Falls back to the raw file only if
        // thumbnail generation fails.
        let imageData: Data
        if let thumb = thumbnailData(from: imageURL) {
            imageData = thumb
        } else {
            imageData = try Data(contentsOf: imageURL)
        }
        let b64 = imageData.base64EncodedString()

        let prompt = """
Describe this photograph in a single flowing paragraph, for someone who cannot \
see it.

Begin immediately with the main subject — your first words should name it \
("A woman...", "Two men...", "A crowd..."). Never open with "The photograph" or \
"The image".

Commit to the physical facts first, and get them right: who is present (state \
apparent gender and rough age when clearly visible), and what each body is \
actually doing — where the hands are and what they hold or touch, whether feet \
are on the ground or in the air, which way the head and eyes are turned and what \
they are aimed at. Name objects precisely. If an object is unusual, out of place, \
or used wrongly — something odd inside a cup, something covering a mouth or face, \
a toy used by an adult — say exactly what it is and where it sits. Transcribe any \
legible text and say what it is printed on.

Then read what is happening between people: whether they engage one another or \
merely share the frame, and the direction of every significant action — who or \
what it is aimed at, offered to, withheld from, blocked by, or received by. If \
someone performs, displays, or broadcasts, say toward whom. If someone watches, \
listens, waits, or strains toward something, say toward what. If two people are \
in physical contact or conflict, say who is doing what to whom.

State emotional register as a conclusion drawn from named evidence: tie every \
emotional word to the visible detail that shows it — "her arms are flung above \
her head mid-jump, exuberant", "his hand is raised toward the other woman's \
swing, blocking it". If you cannot point to the detail, leave the emotion out. \
Never use freestanding mood phrases such as "quiet introspection", "the weight \
of the moment", "lost in thought", "a sense of unease", "raw emotion".

If the frame contains humour, irony, or incongruity — something absurdly out of \
place, a person mirroring a sign, unintended comedy — name it concretely. Note \
any visible symbols — religious, political, commercial, cultural — and how they \
sit in relation to the people around them.

No meta-commentary ("this image evokes", "a snapshot of", "a testament to"), no \
mention of camera, focus, or image quality. English only.
"""

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "images": [b64],
            "stream": false,
            // num_predict raised 250 → 400 → 500. At 250 tokens (~1,000–1,200 chars),
            // 57% of captions were cut mid-sentence; at 400, ~23% still truncated.
            // The v2 prompt typically completes in 140–190 tokens; 500 is headroom.
            //
            // Greedy decoding (temperature 0 + top_k 1), #97: at temperature 0.2,
            // captions hallucinated run-to-run (a nonexistent second figure
            // "mimicking" the subject appeared in one sample and not the next).
            // Greedy is deterministic and removed every observed fabrication on
            // the pilot set. repeat_penalty 1.15 kept as loop insurance — verified
            // harmless with an f16 KV cache (the article corruption it was once
            // suspected of came from OLLAMA_KV_CACHE_TYPE=q8_0; see decision #97).
            "options": ["temperature": 0, "top_k": 1, "num_predict": 500, "repeat_penalty": 1.15]
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

    /// Returns a 768px JPEG-encoded thumbnail of the image at `url`.
    ///
    /// 768px (not the 512px used by CLIP and the thumbnail cache) — captioning
    /// needs more detail than CLIP: at 512px qwen2.5vl missed or misread small
    /// subject-defining objects on the #50 pilot set. Generated fresh from the
    /// original file, so no dependency on the 512px cache. See decision #97.
    private func thumbnailData(from url: URL, maxDimension: Int = 768) -> Data? {
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

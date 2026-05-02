import Foundation
// FIX: @preconcurrency suppresses the warning that MLModel does not conform to Sendable.
// MLModel is an Objective-C class from Apple's CoreML framework that predates Swift concurrency.
// It is safe to hold as a let constant since it is only ever called from within
// a detached Task; @preconcurrency opts us out of the strict Sendable check for this import.
@preconcurrency import CoreML
import CoreGraphics
import ImageIO
import Accelerate

/// Production CLIP inference engine using clip-vit-base-patch32 via Core ML.
///
/// Setup:
///   1. Run `python Tools/convert_clip.py` to produce the .mlpackage.
///   2. Pass the URL of the compiled .mlpackage to the initialiser.
///
/// The model is loaded with computeUnits = .all so the runtime selects
/// ANE → GPU → CPU in order of availability.
public final class CLIPCoreMLEngine: CLIPInferenceEngine {

    static let inputSize: Int = 224
    static let mean: (Float, Float, Float) = (0.48145466, 0.4578275, 0.40821073)
    static let std:  (Float, Float, Float) = (0.26862954, 0.26130258, 0.27577711)

    private let model: MLModel

    /// - Parameter modelURL: URL of the clip-vit-base-patch32.mlpackage (or .mlmodelc).
    public init(modelURL: URL) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw CLIPError.modelNotFound(modelURL)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all

        // MLModel(contentsOf:) requires a compiled .mlmodelc when running outside
        // an app bundle (e.g. from a CLI tool). If given a .mlpackage, compile it
        // first and cache the result in the system temp directory.
        let compiledURL: URL
        if modelURL.pathExtension == "mlpackage" {
            let cacheURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("conjunct-clip-cache")
                .appendingPathComponent(modelURL.lastPathComponent)
                .appendingPathExtension("mlmodelc")

            if FileManager.default.fileExists(atPath: cacheURL.path) {
                compiledURL = cacheURL
            } else {
                print("  Compiling model (one-time, ~30s)…")
                let tempCompiled = try MLModel.compileModel(at: modelURL)
                try FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                // Move from the system-assigned temp location to our cache location
                if FileManager.default.fileExists(atPath: cacheURL.path) {
                    try FileManager.default.removeItem(at: cacheURL)
                }
                try FileManager.default.moveItem(at: tempCompiled, to: cacheURL)
                compiledURL = cacheURL
            }
        } else {
            compiledURL = modelURL
        }

        self.model = try MLModel(contentsOf: compiledURL, configuration: config)
    }

    public func warmUp() async throws {
        let dummy = CGImage.solidColour(width: 224, height: 224, red: 0.5, green: 0.5, blue: 0.5)
        _ = try await embed(image: dummy)
    }

    public func embed(image: CGImage) async throws -> CLIPOutput {
        let start = Date()

        let resized = try image.centreResized(to: Self.inputSize)
        let pixelBuffer = try resized.toNormalisedPixelBuffer(
            mean: Self.mean,
            std: Self.std
        )

        let rawOutput = try await Task.detached(priority: .userInitiated) { [model] in
            let input = try MLDictionaryFeatureProvider(
                dictionary: ["image": MLFeatureValue(pixelBuffer: pixelBuffer)]
            )
            return try model.prediction(from: input)
        }.value

        guard
            let feature = rawOutput.featureValue(for: "embeddings"),
            let multiArray = feature.multiArrayValue
        else {
            throw CLIPError.unexpectedOutputShape
        }

        guard multiArray.count == 512 else {
            throw CLIPError.unexpectedEmbeddingSize(multiArray.count)
        }

        var embedding = (0..<512).map { Float(truncating: multiArray[$0]) }
        l2NormaliseInPlace(&embedding)

        return CLIPOutput(
            embedding: embedding,
            inferenceMs: Date().timeIntervalSince(start) * 1000
        )
    }

    private func l2NormaliseInPlace(_ v: inout [Float]) {
        var normSq: Float = 0
        vDSP_svesq(v, 1, &normSq, vDSP_Length(v.count))
        var norm = sqrt(normSq)
        guard norm > 1e-8 else { return }
        vDSP_vsdiv(v, 1, &norm, &v, 1, vDSP_Length(v.count))
    }

    public enum CLIPError: Error, LocalizedError {
        case modelNotFound(URL)
        case unexpectedOutputShape
        case unexpectedEmbeddingSize(Int)

        public var errorDescription: String? {
            switch self {
            case .modelNotFound(let url):
                return "CLIP model not found at: \(url.path). Run Tools/convert_clip.py first."
            case .unexpectedOutputShape:
                return "CLIP model output did not contain an 'embeddings' multi-array feature."
            case .unexpectedEmbeddingSize(let count):
                return "Expected embedding size 512, got \(count). Check model conversion."
            }
        }
    }
}

// MARK: - CGImage helpers

extension CGImage {

    static func solidColour(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func centreResized(to size: Int) throws -> CGImage {
        let minDim = min(width, height)
        let cropX = (width  - minDim) / 2
        let cropY = (height - minDim) / 2

        guard let cropped = cropping(
            to: CGRect(x: cropX, y: cropY, width: minDim, height: minDim)
        ) else {
            throw ProcessingError.cropFailed
        }

        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: size, height: size))

        guard let result = ctx.makeImage() else {
            throw ProcessingError.resizeFailed
        }
        return result
    }

    func toNormalisedPixelBuffer(
        mean: (Float, Float, Float),
        std: (Float, Float, Float)
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw ProcessingError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ProcessingError.pixelBufferCreationFailed
        }
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    enum ProcessingError: Error {
        case cropFailed
        case resizeFailed
        case pixelBufferCreationFailed
    }
}

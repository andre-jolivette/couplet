import Foundation
import CoreGraphics
import Accelerate

public final class MockCLIPEngine: CLIPInferenceEngine {

    private let simulatedLatencyMs: Double

    public init(simulatedLatencyMs: Double = 30) {
        self.simulatedLatencyMs = simulatedLatencyMs
    }

    public func warmUp() async throws {}

    public func embed(image: CGImage) async throws -> CLIPOutput {
        let start = Date()

        if simulatedLatencyMs > 0 {
            try await Task.sleep(nanoseconds: UInt64(simulatedLatencyMs * 1_000_000))
        }

        var seed = UInt64(image.width &* 31 &+ image.height)
        var embedding = (0..<512).map { _ -> Float in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let bits = UInt32(seed >> 32) & 0x007FFFFF | 0x3F800000
            return Float(bitPattern: bits) * 2 - 3
        }

        var normSq: Float = 0
        vDSP_svesq(embedding, 1, &normSq, 512)
        var norm = sqrt(normSq)
        if norm > 1e-8 {
            vDSP_vsdiv(embedding, 1, &norm, &embedding, 1, 512)
        }

        return CLIPOutput(
            embedding: embedding,
            inferenceMs: Date().timeIntervalSince(start) * 1000
        )
    }
}

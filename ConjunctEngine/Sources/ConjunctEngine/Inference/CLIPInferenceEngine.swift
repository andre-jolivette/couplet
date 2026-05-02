import Foundation
import CoreGraphics

public struct CLIPOutput: Sendable {
    public let embedding: [Float]
    public let inferenceMs: Double
}

public protocol CLIPInferenceEngine: Sendable {
    func embed(image: CGImage) async throws -> CLIPOutput
    func warmUp() async throws
}

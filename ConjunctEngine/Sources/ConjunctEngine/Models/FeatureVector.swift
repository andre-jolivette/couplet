import Foundation
import GRDB

public struct FeatureVector: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// Foreign key to images.id — also the primary key
    public var imageID: Int64
    /// CLIP embedding: float32[512] = 2,048 bytes
    public var clipEmbedding: Data
    /// HSL histogram: float32[1152] = 4,608 bytes (18 hue × 8 sat × 8 lightness bins)
    public var hslHistogram: Data
    /// Dominant palette: float32[18] = 72 bytes (6 LAB colours × 3 channels)
    public var dominantPalette: Data
    /// Edge orientation histogram: float32[32] = 128 bytes
    public var edgeOrientation: Data
    /// Composition grid (4×4): float32[32] = 128 bytes (16 brightness + 16 edge density)
    public var compositionGrid: Data
    public var extractedAt: Date

    public static var databaseTableName = "featureVectors"

    public init(
        imageID: Int64,
        clipEmbedding: [Float],
        hslHistogram: [Float],
        dominantPalette: [Float],
        edgeOrientation: [Float],
        compositionGrid: [Float],
        extractedAt: Date = Date()
    ) {
        self.imageID = imageID
        // FIX: Data(fromFloats:) is not valid initializer syntax for a static method.
        // Must call as Data.fromFloats(_:) instead.
        self.clipEmbedding   = Data.fromFloats(clipEmbedding)
        self.hslHistogram    = Data.fromFloats(hslHistogram)
        self.dominantPalette = Data.fromFloats(dominantPalette)
        self.edgeOrientation = Data.fromFloats(edgeOrientation)
        self.compositionGrid = Data.fromFloats(compositionGrid)
        self.extractedAt     = extractedAt
    }
}

// MARK: - Typed float accessors

public extension FeatureVector {
    var clipEmbeddingFloats: [Float]   { clipEmbedding.toFloats() }
    var hslHistogramFloats: [Float]    { hslHistogram.toFloats() }
    var dominantPaletteFloats: [Float] { dominantPalette.toFloats() }
    var edgeOrientationFloats: [Float] { edgeOrientation.toFloats() }
    var compositionGridFloats: [Float] { compositionGrid.toFloats() }
}

// MARK: - Data ↔ [Float] helpers

public extension Data {
    func toFloats() -> [Float] {
        withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func fromFloats(_ floats: [Float]) -> Data {
        floats.withUnsafeBytes { Data($0) }
    }
}

import Vision
import CoreGraphics
import Foundation

public enum SaliencyAnalyser {

    /// Attention-based visual centroid from a cached thumbnail file.
    /// Returns (x, y) normalized 0–1: left=0/right=1 (x), top=0/bottom=1 (y).
    /// Returns nil when Vision finds no salient regions (near-blank or uniform images).
    public static func attentionCentroid(thumbnailURL: URL) throws -> (x: Float, y: Float)? {
        guard let imageSource = CGImageSourceCreateWithURL(thumbnailURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first as? VNSaliencyImageObservation,
              let objects = observation.salientObjects,
              !objects.isEmpty else {
            return nil
        }

        let totalConf = objects.reduce(0.0) { $0 + Double($1.confidence) }
        guard totalConf > 0 else { return nil }

        var cx = 0.0, cy = 0.0
        for obj in objects {
            let w = Double(obj.confidence) / totalConf
            cx += obj.boundingBox.midX * w
            cy += obj.boundingBox.midY * w
        }
        // Vision bounding boxes use bottom-left origin; flip Y to match top-left convention.
        return (x: Float(cx), y: Float(1.0 - cy))
    }
}

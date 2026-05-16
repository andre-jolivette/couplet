import Vision
import CoreGraphics
import Foundation

public enum SaliencyAnalyser {

    /// Visual centroid of the primary subject in a cached thumbnail.
    /// Returns (x, y) normalized 0–1: left=0/right=1 (x), top=0/bottom=1 (y).
    /// Returns nil when no subject can be located (featureless or uniform images).
    ///
    /// Strategy (two requests run in a single pass):
    ///   1. VNDetectHumanRectanglesRequest — tight per-person bounding boxes,
    ///      area-weighted centroid. Used when ≥1 human detected with confidence ≥ 0.3.
    ///      Best signal for street/documentary photography where the subject is a person.
    ///   2. VNGenerateAttentionBasedSaliencyImageRequest — confidence-weighted centroid
    ///      of salient regions. Fallback for non-human subjects (animals, objects,
    ///      architectural details, abstracts).
    public static func attentionCentroid(thumbnailURL: URL) throws -> (x: Float, y: Float)? {
        guard let imageSource = CGImageSourceCreateWithURL(thumbnailURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        let humanRequest    = VNDetectHumanRectanglesRequest()
        let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([humanRequest, saliencyRequest])

        // Primary: individual human bounding boxes, weighted by area.
        // Area weighting favours closer / larger subjects over background figures.
        let humans = (humanRequest.results ?? []).filter { $0.confidence >= 0.3 }
        if !humans.isEmpty {
            let totalArea = humans.reduce(0.0) {
                $0 + Double($1.boundingBox.width * $1.boundingBox.height)
            }
            if totalArea > 0 {
                var cx = 0.0, cy = 0.0
                for h in humans {
                    let w = Double(h.boundingBox.width * h.boundingBox.height) / totalArea
                    cx += h.boundingBox.midX * w
                    cy += h.boundingBox.midY * w
                }
                // Vision bounding boxes use bottom-left origin; flip Y to top-left convention.
                return (x: Float(cx), y: Float(1.0 - cy))
            }
        }

        // Fallback: attention saliency for non-human subjects.
        guard let observation = saliencyRequest.results?.first as? VNSaliencyImageObservation,
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
        return (x: Float(cx), y: Float(1.0 - cy))
    }
}

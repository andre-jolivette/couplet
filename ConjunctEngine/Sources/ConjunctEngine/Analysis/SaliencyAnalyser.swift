import Vision
import CoreGraphics
import Foundation

/// Per-image spatial features extracted in a single Vision pass over the 512px thumbnail.
public struct ImageSpatialFeatures: Sendable {
    /// Confidence-weighted subject position, normalized 0–1 (left=0/right=1 x, top=0/bottom=1 y).
    /// nil when no subject detected (featureless or uniform images).
    public let centroid: (x: Float, y: Float)?
    /// Face gaze direction: -1.0=looking left, +1.0=looking right.
    /// Extracted from VNDetectFaceLandmarksRequest pupil positions (primary) or
    /// head yaw from nose/eye geometry (fallback). nil when no face detected or
    /// landmarks are unreliable. See decision #65.
    public let gazeDirectionX: Float?
}

public enum SaliencyAnalyser {

    /// Extracts subject centroid and face gaze direction from a cached thumbnail.
    ///
    /// Three Vision requests run in a single pass:
    ///   1. VNDetectHumanRectanglesRequest — tight per-person bounding boxes,
    ///      area-weighted centroid. Used when ≥1 human detected with confidence ≥ 0.3.
    ///      Best signal for street/documentary photography where the subject is a person.
    ///   2. VNGenerateAttentionBasedSaliencyImageRequest — confidence-weighted centroid
    ///      of salient regions. Fallback for non-human subjects (animals, objects,
    ///      architectural details, abstracts).
    ///   3. VNDetectFaceLandmarksRequest — 76 landmark points per face. Primary gaze
    ///      signal via pupil offset within eye contour; head yaw as fallback.
    ///      Independent of the centroid path — a face-detection failure still returns
    ///      the centroid, and vice versa.
    public static func analyse(thumbnailURL: URL) throws -> ImageSpatialFeatures {
        guard let imageSource = CGImageSourceCreateWithURL(thumbnailURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return ImageSpatialFeatures(centroid: nil, gazeDirectionX: nil)
        }

        let humanRequest    = VNDetectHumanRectanglesRequest()
        let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        let faceRequest     = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([humanRequest, saliencyRequest, faceRequest])

        // ── Centroid ────────────────────────────────────────────────────────
        // Primary: individual human bounding boxes, weighted by area.
        // Area weighting favours closer / larger subjects over background figures.
        let centroid: (x: Float, y: Float)?
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
                centroid = (x: Float(cx), y: Float(1.0 - cy))
            } else {
                centroid = nil
            }
        } else {
            // Fallback: attention saliency for non-human subjects.
            if let observation = saliencyRequest.results?.first as? VNSaliencyImageObservation,
               let objects = observation.salientObjects,
               !objects.isEmpty {
                let totalConf = objects.reduce(0.0) { $0 + Double($1.confidence) }
                if totalConf > 0 {
                    var cx = 0.0, cy = 0.0
                    for obj in objects {
                        let w = Double(obj.confidence) / totalConf
                        cx += obj.boundingBox.midX * w
                        cy += obj.boundingBox.midY * w
                    }
                    centroid = (x: Float(cx), y: Float(1.0 - cy))
                } else {
                    centroid = nil
                }
            } else {
                centroid = nil
            }
        }

        // ── Gaze direction ──────────────────────────────────────────────────
        // Use the largest/highest-confidence face only — most prominent subject.
        let gaze = faceRequest.results?.first.flatMap { gazeFromLandmarks($0) }

        return ImageSpatialFeatures(centroid: centroid, gazeDirectionX: gaze)
    }

    // MARK: - Gaze extraction

    /// Extracts gaze direction [-1.0=left, +1.0=right] from face landmarks.
    /// Pupil offset within eye contour. Returns nil when pupils are not detected
    /// (face tilted, eyes closed, profile) — no head-yaw fallback, which produced
    /// false positives on tilted/recumbent faces. See decision #69.
    private static func gazeFromLandmarks(_ obs: VNFaceObservation) -> Float? {
        guard let lm       = obs.landmarks,
              let leftEye  = lm.leftEye,
              let rightEye = lm.rightEye,
              let leftPup  = lm.leftPupil?.normalizedPoints.first,
              let rightPup = lm.rightPupil?.normalizedPoints.first else { return nil }

        func pupilOffset(eye: VNFaceLandmarkRegion2D, pupil: CGPoint) -> Float? {
            let xs = eye.normalizedPoints.map { $0.x }
            guard let minX = xs.min(), let maxX = xs.max(),
                  (maxX - minX) > 0.05 else { return nil }  // eye too small → skip
            // 0 = pupil at leftmost edge of eye, 1 = rightmost edge
            return Float((pupil.x - minX) / (maxX - minX))
        }

        guard let lo = pupilOffset(eye: leftEye,  pupil: leftPup),
              let ro = pupilOffset(eye: rightEye, pupil: rightPup) else { return nil }

        // Average offset [0,1] → [-1,+1].
        // High value = pupils toward right of their respective eyes = looking right.
        return (lo + ro) - 1.0
    }
}

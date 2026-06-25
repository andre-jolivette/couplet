import Vision
import CoreGraphics
import CoreVideo
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
    /// Number of detected faces (VNDetectFaceLandmarksRequest). The gaze nominator
    /// (#109) requires exactly 1 — a single unambiguous looker whose gaze belongs to
    /// the sole face (gazeDirectionX is taken from the first face, so >1 is unreliable).
    public let faceCount: Int
    /// Number of detected humans (confidence ≥ 0.3). Tuning headroom for the
    /// future "2 people, one dominant looker" loosening. See decision #109.
    public let humanCount: Int
    /// Concentration of the attention-saliency heatmap ∈ [0,1] — 1.0 = one tight
    /// dominant subject, → 0 = attention spread across the frame (crowd / scattered
    /// subjects). The nominator requires a high value on the TARGET so the gaze has
    /// one clear thing to land on. nil when no saliency. See decision #109.
    public let subjectDominance: Float?

    public init(centroid: (x: Float, y: Float)?, gazeDirectionX: Float?,
                faceCount: Int = 0, humanCount: Int = 0, subjectDominance: Float? = nil) {
        self.centroid = centroid; self.gazeDirectionX = gazeDirectionX
        self.faceCount = faceCount; self.humanCount = humanCount
        self.subjectDominance = subjectDominance
    }
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

        let saliencyObs = saliencyRequest.results?.first as? VNSaliencyImageObservation
        let dominance = saliencyObs.flatMap { saliencyDominance($0) }
        let faceCount = faceRequest.results?.count ?? 0

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
            if let observation = saliencyObs,
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

        return ImageSpatialFeatures(centroid: centroid, gazeDirectionX: gaze,
                                    faceCount: faceCount, humanCount: humans.count,
                                    subjectDominance: dominance)
    }

    // MARK: - Subject dominance

    /// Concentration of the attention-saliency heatmap ∈ [0,1]: 1.0 = all attention
    /// in one tight region (a single dominant subject), → 0 = attention spread evenly
    /// across the frame (a crowd or scattered subjects). Computed as 1 minus the
    /// saliency-weighted spatial variance normalized by the uniform-spread variance
    /// (≈ 1/6 over the unit square). One extra pass over the small (~68×68) heatmap.
    private static func saliencyDominance(_ observation: VNSaliencyImageObservation) -> Float? {
        let pb = observation.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pb)

        var mass = 0.0, sx = 0.0, sy = 0.0
        for y in 0..<h {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
            for x in 0..<w {
                let v = Double(max(0, row[x]))
                mass += v; sx += v * Double(x); sy += v * Double(y)
            }
        }
        guard mass > 0 else { return nil }
        let cx = sx / mass, cy = sy / mass

        var variance = 0.0
        for y in 0..<h {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
            for x in 0..<w {
                let v = Double(max(0, row[x]))
                let dx = (Double(x) - cx) / Double(w)
                let dy = (Double(y) - cy) / Double(h)
                variance += v * (dx * dx + dy * dy)
            }
        }
        variance /= mass
        // Uniform spread over [0,1]² → variance ≈ 1/6; a tight blob → ~0.
        return Float(max(0, 1.0 - min(1.0, variance / (1.0 / 6.0))))
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

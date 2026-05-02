import Foundation
import ConjunctEngine

/// Thin wrapper so AppModels.swift can call ConceptClusters without
/// importing ConjunctEngine everywhere.
enum ConjunctConceptClusters {
    static func matchedClusters(for caption: String) -> Set<String> {
        ConceptClusters.matchedClusters(for: caption)
    }
}

// SettingsStore.swift
// Couplet
//
// UserDefaults-backed store for runtime-adjustable scoring settings.
// Observed by EngineController, which re-runs fetchPairs when values change.
// The engine (ConjunctEngine) remains configuration-agnostic — values are
// passed in at call time from this store.

import Foundation
import ConjunctEngine

@Observable
final class SettingsStore {

    // MARK: - UserDefaults keys

    private enum Key {
        static let weights              = "com.toastbrigade.Couplet.scoringWeights"
        static let minThematicScore     = "com.toastbrigade.Couplet.minThematicScore"
        static let edgePeakednessFloor  = "com.toastbrigade.Couplet.edgePeakednessFloor"
        static let gridVarianceFloor    = "com.toastbrigade.Couplet.gridVarianceFloor"
        static let hideSequential       = "com.toastbrigade.Couplet.hideSequential"
    }

    // MARK: - Published settings

    /// Composite scoring weights for aesthetic, geometric, and thematic modalities.
    /// Always sum to 1.0 (enforced by ScoringWeights / TriangleWeightPicker).
    var weights: ScoringWeights {
        didSet {
            guard weights != oldValue else { return }
            if let data = try? JSONEncoder().encode(weights) {
                UserDefaults.standard.set(data, forKey: Key.weights)
            }
        }
    }

    /// Minimum thematic score a pair must reach to appear in the grid.
    /// Default 0.0 (no filtering). Range 0.0–1.0.
    var minThematicScore: Float {
        didSet {
            guard minThematicScore != oldValue else { return }
            UserDefaults.standard.set(minThematicScore, forKey: Key.minThematicScore)
        }
    }

    /// Hard floor for display-time geometric gating based on edge dominance.
    /// Pairs where max(edgePeakedness_A, edgePeakedness_B) falls below this have
    /// their edge similarity discounted to 40% — applied after the continuous
    /// distinctiveness multiplier. ~1.0 = no gating; ~3.0 = only strongly-lined images.
    /// Default 2.2 — sits just above the library p10 (~2.16) to filter the least
    /// directional pairs without touching the majority.
    var edgePeakednessFloor: Float {
        didSet {
            guard edgePeakednessFloor != oldValue else { return }
            UserDefaults.standard.set(edgePeakednessFloor, forKey: Key.edgePeakednessFloor)
        }
    }

    /// When true, pairs captured within 10 seconds of each other are hidden from the grid.
    var hideSequential: Bool {
        didSet {
            guard hideSequential != oldValue else { return }
            UserDefaults.standard.set(hideSequential, forKey: Key.hideSequential)
        }
    }

    /// Hard floor for display-time geometric gating based on composition structure.
    /// Pairs where max(gridVariance_A, gridVariance_B) falls below this have their
    /// grid similarity discounted to 50% — applied after the continuous distinctiveness
    /// multiplier. ~0.0 = no gating; ~0.20 = only images with clear tonal structure.
    /// Default 0.12 — sits just above the library p10 (~0.116).
    var gridVarianceFloor: Float {
        didSet {
            guard gridVarianceFloor != oldValue else { return }
            UserDefaults.standard.set(gridVarianceFloor, forKey: Key.gridVarianceFloor)
        }
    }

    // MARK: - Init

    init() {
        // Weights — decode from JSON, fall back to engine default
        if let data    = UserDefaults.standard.data(forKey: Key.weights),
           let decoded = try? JSONDecoder().decode(ScoringWeights.self, from: data) {
            weights = decoded
        } else {
            weights = .default
        }

        // Thematic threshold — stored as Float, default 0
        minThematicScore = UserDefaults.standard.object(forKey: Key.minThematicScore)
            .flatMap { $0 as? Float } ?? 0.0

        // Geometric floors — persist across launches, default to library-calibrated values
        edgePeakednessFloor = UserDefaults.standard.object(forKey: Key.edgePeakednessFloor)
            .flatMap { $0 as? Float } ?? 2.2
        gridVarianceFloor = UserDefaults.standard.object(forKey: Key.gridVarianceFloor)
            .flatMap { $0 as? Float } ?? 0.12

        hideSequential = UserDefaults.standard.bool(forKey: Key.hideSequential)
    }

    // MARK: - Reset

    func resetWeights() {
        weights = .default
    }

    func resetAll() {
        weights             = .default
        minThematicScore    = 0.0
        edgePeakednessFloor = 2.2
        gridVarianceFloor   = 0.12
        hideSequential      = false
    }
}

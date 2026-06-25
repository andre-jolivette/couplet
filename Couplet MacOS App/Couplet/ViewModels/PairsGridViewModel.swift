import Foundation
import Combine
import SwiftUI

@MainActor
final class PairsGridViewModel: ObservableObject {

    @Published private(set) var allPairs: [DisplayPair] = []
    @Published var isLoading: Bool = false
    @Published private(set) var isLoadingMore: Bool = false
    @Published var selectedModality: PairingModality? = nil
    @Published var showRejected: Bool = false
    @Published var hideSequential: Bool = false
    @Published var colorToneFilter: DisplayPair.ColorTone? = nil
    @Published var searchText: String = ""
    @Published var sortOrder: PairSortOrder = .axis
    @Published var minimumConfidence: Float = 0.0
    @Published var anchorImageID: Int? = nil
    @Published var anchorFilename: String? = nil

    private var currentPage: Int = 0
    private(set) var canLoadMore: Bool = true
    private let pageSize = 150
    private var loadTask: Task<Void, Never>?
    private var silentRefreshTask: Task<Void, Never>?

    // Lightbox trigger — owned here so ContentView can observe it
    @Published var lightboxPairID: Int? = nil
    @Published var lightboxStartIndex: Int = 0

    var isAnchored: Bool { anchorImageID != nil }

    func applyAnchor(imageID: Int, filename: String) {
        anchorImageID = imageID; anchorFilename = filename
    }
    func releaseAnchor() { anchorImageID = nil; anchorFilename = nil }
    func openLightbox(pairID: Int) {
        let pairs = displayedPairs
        lightboxStartIndex = pairs.firstIndex(where: { $0.id == pairID }) ?? 0
        lightboxPairID = pairID
    }
    func closeLightbox() { lightboxPairID = nil }

    func loadPairs(from engine: EngineController, folderID: Int64? = nil, collectionID: Int64? = nil) {
        loadTask?.cancel()
        currentPage = 0
        canLoadMore = false
        allPairs = []
        isLoading = true
        loadTask = Task {
            // Debounce: if cancelled during the sleep, a newer loadPairs call is pending.
            // This prevents rapid navigation from queueing multiple queries on the DB actor.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            // streamPage0Pairs fetches in 20-row chunks and yields accepted batches as
            // they arrive so LazyVGrid can start rendering before the full query completes.
            // The stream also populates representativePairsCache on completion so that
            // any future loadMorePairs call can still slice from it.
            let stream = engine.streamPage0Pairs(
                folderID: folderID, collectionID: collectionID, sortOrder: sortOrder
            )
            for await batch in stream {
                guard !Task.isCancelled else { break }
                self.allPairs.append(contentsOf: batch)
                // Show the grid as soon as the first batch arrives so LazyVGrid
                // starts rendering while remaining chunks are still in flight.
                if self.isLoading { self.isLoading = false }
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            self.isLoading = false
        }
    }

    /// Refreshes the grid in the background without clearing `allPairs` or showing a spinner.
    /// Used for incremental ThematicV2 batch updates — pairs rearrange in place rather than
    /// the whole screen wiping. Cancels any pending silent refresh but never touches `loadTask`.
    func silentRefresh(from engine: EngineController, folderID: Int64? = nil, collectionID: Int64? = nil) {
        // Don't run a silent refresh while a full load is already streaming — the full
        // load will land shortly and already reflects the latest V2 scores.
        guard !isLoading else { return }
        silentRefreshTask?.cancel()
        silentRefreshTask = Task {
            // Short debounce so rapid batch ticks (e.g. two pairs scored within the same
            // frame) collapse into a single DB round-trip.
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            var buffer: [DisplayPair] = []
            let stream = engine.streamPage0Pairs(
                folderID: folderID, collectionID: collectionID, sortOrder: sortOrder,
                triggerThematicPass: false
            )
            for await batch in stream {
                guard !Task.isCancelled else { return }
                buffer.append(contentsOf: batch)
            }
            guard !Task.isCancelled else { return }
            // Preserve any in-flight decision mutations the user made during this session.
            // Decisions are also persisted to DB immediately, so the next full load would
            // read them correctly — this just prevents a brief visual reset mid-session.
            let decisionsByID = Dictionary(uniqueKeysWithValues: allPairs.compactMap { p -> (Int, PairDecision)? in
                p.decision != .none ? (p.id, p.decision) : nil
            })
            for i in buffer.indices {
                if let d = decisionsByID[buffer[i].id] { buffer[i].decision = d }
            }
            withAnimation(.easeInOut(duration: 0.25)) {
                self.allPairs = buffer
            }
        }
    }

    func loadMorePairs(from engine: EngineController, folderID: Int64? = nil, collectionID: Int64? = nil) {
        guard canLoadMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        let nextPage = currentPage + 1
        Task {
            let morePairs = await engine.fetchRepresentativePairs(
                folderID: folderID, collectionID: collectionID, sortOrder: sortOrder, page: nextPage
            )
            if morePairs.isEmpty {
                self.canLoadMore = false
            } else {
                // Deduplicate: skip any pair IDs already in allPairs
                // (can happen at page boundaries due to the cap-2 filter).
                let existingIDs = Set(self.allPairs.map(\.id))
                let newPairs = morePairs.filter { !existingIDs.contains($0.id) }
                self.allPairs.append(contentsOf: newPairs)
                self.currentPage = nextPage
                self.canLoadMore = morePairs.count == pageSize
            }
            self.isLoadingMore = false
        }
    }

    func removePair(id: Int) {
        allPairs.removeAll { $0.id == id }
    }

    var displayedPairs: [DisplayPair] {
        var result = allPairs
        if !showRejected { result = result.filter { $0.decision != .rejected && $0.decision != .deleted } }
        if hideSequential { result = result.filter { !$0.isSequential } }
        if let tone = colorToneFilter { result = result.filter { $0.colorTone == tone } }
        if let id = anchorImageID { result = result.filter { $0.imageAID == id || $0.imageBID == id } }
        if let m = selectedModality { result = result.filter { $0.modality == m } }
        if minimumConfidence > 0 { result = result.filter { $0.compositeScore >= minimumConfidence } }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { result = result.filter {
            $0.filenameA.lowercased().contains(q) || $0.filenameB.lowercased().contains(q) ||
            $0.folderA.lowercased().contains(q) || $0.folderB.lowercased().contains(q)
        }}
        switch sortOrder {
        case .axis:      result.sort { $0.axisScore      > $1.axisScore      }
        case .composite: result.sort { $0.compositeScore > $1.compositeScore }
        case .thematic:  result.sort { $0.thematicScore  > $1.thematicScore  }
        case .geometric: result.sort { $0.geometricScore > $1.geometricScore }
        case .aesthetic: result.sort { $0.aestheticScore > $1.aestheticScore }
        }
        return result
    }

    var pairCount: Int { displayedPairs.count }
    var allPairsForAnchor: [DisplayPair] { allPairs }

    func applyDecision(id: Int, decision: PairDecision, engine: EngineController? = nil) {
        guard let idx = allPairs.firstIndex(where: { $0.id == id }) else { return }
        switch decision {
        case .liked:
            let next: PairDecision = allPairs[idx].decision == .liked ? .none : .liked
            allPairs[idx].decision = next
            engine?.saveDecision(pairID: Int64(id), decision: next == .liked ? "liked" : "none")
        case .rejected:
            let next: PairDecision = allPairs[idx].decision == .rejected ? .none : .rejected
            allPairs[idx].decision = next
            engine?.saveDecision(pairID: Int64(id), decision: next == .rejected ? "rejected" : "none")
        case .deleted:
            allPairs[idx].decision = .deleted
            engine?.deletePair(pairID: Int64(id))
        case .none:
            allPairs[idx].decision = .none
        }
    }

    func likePair(id: Int, engine: EngineController? = nil)   { applyDecision(id: id, decision: .liked, engine: engine) }
    func rejectPair(id: Int, engine: EngineController? = nil) { applyDecision(id: id, decision: .rejected, engine: engine) }
    func deletePair(id: Int, engine: EngineController? = nil) { applyDecision(id: id, decision: .deleted, engine: engine) }

    func clearFilters() {
        selectedModality = nil; showRejected = false
        colorToneFilter = nil; searchText = ""; sortOrder = .axis; minimumConfidence = 0.0
    }

    var hasActiveFilters: Bool {
        selectedModality != nil || showRejected || colorToneFilter != nil ||
        !searchText.isEmpty || minimumConfidence > 0 || isAnchored
    }
}

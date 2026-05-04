import Foundation
import Combine

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
    @Published var sortOrder: PairSortOrder = .composite
    @Published var minimumConfidence: Float = 0.0
    @Published var anchorImageID: Int? = nil
    @Published var anchorFilename: String? = nil

    private var currentPage: Int = 0
    private(set) var canLoadMore: Bool = true
    private let pageSize = 150
    private var loadTask: Task<Void, Never>?

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
                // Yield to the main-actor run loop so SwiftUI renders this batch
                // before the next one arrives. Without this, AsyncStream's unbounded
                // buffer lets the producer fill all batches before the consumer runs,
                // causing SwiftUI to coalesce everything into a single render.
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            self.isLoading = false
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
            allPairs[idx].decision = .rejected
            engine?.saveDecision(pairID: Int64(id), decision: "rejected")
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
        colorToneFilter = nil; searchText = ""; sortOrder = .composite; minimumConfidence = 0.0
    }

    var hasActiveFilters: Bool {
        selectedModality != nil || showRejected || colorToneFilter != nil ||
        !searchText.isEmpty || minimumConfidence > 0 || isAnchored
    }
}

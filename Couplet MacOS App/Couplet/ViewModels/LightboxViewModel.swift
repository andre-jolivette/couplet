import SwiftUI
import Combine

@MainActor
final class LightboxViewModel: ObservableObject {

    // MARK: - Pair list

    @Published private(set) var pairs: [DisplayPair] = []
    @Published private(set) var currentIndex: Int = 0

    var currentPair: DisplayPair? {
        guard pairs.indices.contains(currentIndex) else { return nil }
        return pairs[currentIndex]
    }

    var pairCount: Int { pairs.count }

    // MARK: - Anchor state

    @Published private(set) var anchorImageID: Int? = nil
    @Published private(set) var anchorFilename: String? = nil
    @Published private(set) var anchorColor: NSColor? = nil

    var isAnchored: Bool { anchorImageID != nil }

    // MARK: - Transient controls

    @Published var controlsVisible: Bool = true
    @Published var infoPinned: Bool = false

    private var hideTimer: AnyCancellable?
    private let hideDuration: TimeInterval = 3.5

    /// In-flight anchor fetch. Cancelled on release or on switching anchors,
    /// preventing a stale fetch from overwriting `pairs` after release.
    private var anchorFetchTask: Task<Void, Never>?

    // MARK: - Toast

    @Published var toastMessage: String? = nil
    private var toastTimer: AnyCancellable?

    // MARK: - Setup

    func open(pairs: [DisplayPair], startingAt index: Int) {
        self.pairs = pairs
        self.currentIndex = max(0, min(index, pairs.count - 1))
        anchorImageID = nil
        anchorFilename = nil
        anchorColor = nil
        showControls()
    }

    // MARK: - Navigation

    func goNext() {
        guard currentIndex < pairs.count - 1 else { return }
        currentIndex += 1
        showControls()
    }

    func goPrevious() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        showControls()
    }

    func jumpTo(index: Int) {
        guard pairs.indices.contains(index) else { return }
        currentIndex = index
        showControls()
    }

    func jumpTo(pairID: Int) {
        guard let index = pairs.firstIndex(where: { $0.id == pairID }) else { return }
        currentIndex = index
        showControls()
    }

    var canGoNext: Bool { currentIndex < pairs.count - 1 }
    var canGoPrevious: Bool { currentIndex > 0 }

    // MARK: - Anchor

    /// Clicking an image toggles anchor:
    /// - If not anchored, sets this image as anchor and fetches all its pairs from DB.
    /// - If this image is already the anchor, releases it.
    /// - If a different image is the anchor, switches to this one.
    ///
    /// `onFetch` is an async closure provided by the view layer that calls
    /// `EngineController.fetchPairs(anchorImageID:)` — keeps DB access out of the VM.
    func toggleAnchor(
        imageID: Int, filename: String, color: NSColor,
        onFetch: @escaping (Int) async -> [DisplayPair],
        allPairs: [DisplayPair]
    ) {
        if anchorImageID == imageID {
            // Already anchored — release
            releaseAnchor(allPairs: allPairs)
            return
        }

        anchorImageID = imageID
        anchorFilename = filename
        anchorColor = color
        currentIndex = 0
        showControls()

        // Cancel any in-flight fetch from a previous anchor before starting a new one.
        anchorFetchTask?.cancel()

        // Fetch all pairs for this image from DB (up to 200, the anchor limit).
        // Falls back to the in-memory set if the fetch returns nothing.
        anchorFetchTask = Task { @MainActor in
            let fetched = await onFetch(imageID)
            // Guard against the anchor having been released while the fetch was in flight.
            guard !Task.isCancelled, self.anchorImageID == imageID else { return }
            if !fetched.isEmpty {
                self.pairs = fetched
            } else {
                let fallback = allPairs.filter { $0.imageAID == imageID || $0.imageBID == imageID }
                self.pairs = fallback.isEmpty ? allPairs : fallback
                if fallback.isEmpty {
                    self.showToast("No pairs found for \(filename)")
                }
            }
        }
    }

    func releaseAnchor(allPairs: [DisplayPair]) {
        // Cancel any in-flight fetch so it can't overwrite `pairs` after release.
        anchorFetchTask?.cancel()
        anchorFetchTask = nil

        let currentPairID = currentPair?.id
        anchorImageID = nil
        anchorFilename = nil
        anchorColor = nil

        // Compute the target index BEFORE swapping the pairs array so that when
        // SwiftUI re-renders after `pairs` changes, currentPair resolves correctly
        // into allPairs with no intermediate flash to a wrong pair.
        let targetIndex: Int
        if let id = currentPairID,
           let idx = allPairs.firstIndex(where: { $0.id == id }) {
            targetIndex = idx
        } else {
            // Pair was fetched by anchor DB query but isn't in the main grid list;
            // fall back to top of the list rather than an arbitrary stale index.
            targetIndex = 0
        }
        currentIndex = targetIndex
        pairs = allPairs

        showToast("Anchor released")
        showControls()
    }

    // MARK: - Decision sync

    func syncDecision(id: Int, decision: PairDecision) {
        guard let idx = pairs.firstIndex(where: { $0.id == id }) else { return }
        if decision == .liked {
            pairs[idx].decision = pairs[idx].decision == .liked ? .none : .liked
        } else {
            pairs[idx].decision = decision
        }
    }

    // MARK: - Controls visibility

    func showControls() {
        controlsVisible = true
        resetHideTimer()
    }

    func toggleControls() {
        if controlsVisible {
            hideTimer?.cancel()
            controlsVisible = false
        } else {
            showControls()
        }
    }

    func toggleInfoPin() {
        infoPinned.toggle()
        if infoPinned { hideTimer?.cancel() }
        else { resetHideTimer() }
    }

    private func resetHideTimer() {
        hideTimer?.cancel()
        guard !infoPinned else { return }
        hideTimer = Just(())
            .delay(for: .seconds(hideDuration), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.controlsVisible = false
                }
            }
    }

    // MARK: - Toast

    func showToast(_ message: String) {
        toastMessage = message
        toastTimer?.cancel()
        toastTimer = Just(())
            .delay(for: .seconds(2.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                withAnimation(.easeOut(duration: 0.4)) {
                    self?.toastMessage = nil
                }
            }
    }
}

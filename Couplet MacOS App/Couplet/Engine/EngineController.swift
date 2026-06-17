import Foundation
import Combine
import SwiftUI
import ConjunctEngine

@MainActor
final class EngineController: ObservableObject {

    // MARK: - Published state

    @Published var folders: [FolderItem] = []
    @Published var isIndexing: Bool = false
    @Published var isBackgroundScoring: Bool = false
    /// True only while genuine cross-folder scoring is running (multiple active
    /// folders/batches). Drives the "Scoring cross-folder pairs" label; otherwise the
    /// background chip shows "Iterating on thematic concepts".
    @Published var isScoringCrossFolder: Bool = false
    @Published var indexingProgress: IndexingProgress? = nil
    @Published var hasAnyFolders: Bool = false
    /// True once a real CLIPCoreMLEngine is loaded (not mock)
    @Published private(set) var hasRealCLIP: Bool = false
    @Published private(set) var captioningAvailable: Bool = false
    /// Total pair count per image (both sides), in the current folder context.
    /// Refreshed on every page-0 load of representative pairs.
    @Published private(set) var imagePairCounts: [Int: Int] = [:]
    /// True while ThematicV2BackgroundPass is running. Transitions false→true on start, true→false on finish.
    @Published private(set) var isThematicV2Running: Bool = false
    /// Pairs scored so far in the current ThematicV2 pass. Reset to 0 on each new pass.
    @Published private(set) var thematicV2Scored: Int = 0
    /// Total candidates in the current ThematicV2 pass. Set when candidates are fetched.
    @Published private(set) var thematicV2Total: Int = 0
    /// Increments by 1 every kThematicV2BatchSize pairs scored. Watched by PairsGridView
    /// to trigger incremental grid reloads mid-pass rather than waiting for completion.
    @Published private(set) var thematicV2BatchCount: Int = 0

    // MARK: - Settings

    let settings: SettingsStore

    // MARK: - Engine objects

    private var db: DatabaseManager?
    private var queryService: QueryService?
    private var indexingEngine: IndexingEngine?
    /// Tracked so we can cancel an in-progress build if a new one starts
    private var engineBuildTask: Task<Void, Never>?
    /// Stream-listening task for the active indexing run — cancelled when re-indexing starts.
    private var indexStreamTask: Task<Void, Never>?
    /// Background LLM scoring pass — cancelled when a new index starts, restarted after page-0 load.
    private var thematicV2PassTask: Task<Void, Never>?

    /// Full cap-2-filtered representative pair list for the current folder/sort context.
    /// Populated on page-0 fetch; subsequent pages slice from this cache.
    /// The key tracks which context the cache belongs to — stale slices are rejected.
    private var representativePairsCache: [DisplayPair] = []
    private var representativePairsCacheKey: (folderID: Int64?, collectionID: Int64?, sortColumn: String) = (nil, nil, "")
    private var loadGeneration: Int = 0

    /// Grid reloads during ThematicV2 pass every this many pairs scored.
    private static let kThematicV2BatchSize = 10

    private let thumbnailBaseURL: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Conjunct/thumbnails")

    // MARK: - Initialisation

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func initialize() {
        do {
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let supportDir = appSupport.appendingPathComponent("Conjunct")
            try FileManager.default.createDirectory(
                at: supportDir, withIntermediateDirectories: true
            )
            let dbURL = supportDir.appendingPathComponent("conjunct.db")
            let database = try DatabaseManager(url: dbURL)
            db = database
            queryService = QueryService(db: database)
            startEngineBuild(db: database)
            Task { await self.refreshFolders() }
        } catch {
            print("EngineController init error: \(error)")
        }
    }

    // MARK: - Add folder

    func addFolder(url: URL) {
        // Persist a security-scoped bookmark immediately while sandbox access is live.
        // This lets export (and any future feature) open source files without asking again.
        FolderBookmarks.store(url: url)

        // Update or add sidebar entry immediately so the user sees something
        if let idx = folders.firstIndex(where: { $0.path == url.path }) {
            folders[idx] = FolderItem(
                id: folders[idx].id, displayName: url.lastPathComponent,
                path: url.path, driveType: folders[idx].driveType,
                imageCount: folders[idx].imageCount, pairCount: folders[idx].pairCount,
                isIndexing: true, indexingFraction: nil
            )
        } else {
            folders.append(FolderItem(
                id: -1, displayName: url.lastPathComponent, path: url.path,
                driveType: detectDriveType(url), imageCount: 0, pairCount: 0,
                isIndexing: true, indexingFraction: nil
            ))
        }
        hasAnyFolders = true

        // Engine may still be compiling the CLIP model — retry after 0.5s
        guard let engine = indexingEngine else {
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.addFolderIndexing(url: url)
            }
            return
        }
        addFolderIndexing(url: url, engine: engine)
    }

    private func addFolderIndexing(url: URL, engine: IndexingEngine? = nil) {
        let engine = engine ?? self.indexingEngine
        guard let engine else {
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.addFolderIndexing(url: url)
            }
            return
        }

        isIndexing = true
        isBackgroundScoring = false
        isScoringCrossFolder = false
        indexingProgress = IndexingProgress(phase: .scanning, itemsComplete: 0, itemsTotal: 0)

        thematicV2PassTask?.cancel()
        thematicV2PassTask = nil
        indexStreamTask?.cancel()
        indexStreamTask = Task {
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            let settings = DuplicateSettings(
                hammingThreshold: 6, allowIntraStackPairing: false, showReviewPrompt: false
            )
            let stream = await engine.index(folderURL: url, duplicateSettings: settings, topK: 150)

            var lastPublish = Date.distantPast
            var lastPhase: IndexingProgress.Phase? = nil
            let minInterval: TimeInterval = 0.3

            for await progress in stream {
                let now = Date()
                let phaseChanged = progress.phase != lastPhase
                let intervalElapsed = now.timeIntervalSince(lastPublish) >= minInterval
                // Phase 1 done: folder is browsable, clear indexing state immediately.
                let isFolderReady = progress.phase == .complete
                // Stream done: phase 2 finished (or error) — All view can refresh.
                let isStreamDone = progress.phase == .backgroundScoringComplete
                    || progress.phase == .failed
                // Background phases are silent — don't publish to UI progress card.
                let isVisible = progress.phase != .backgroundScoring
                    && progress.phase != .scoringCrossFolder
                    && progress.phase != .backgroundScoringComplete

                if (phaseChanged || intervalElapsed || isFolderReady || isStreamDone) && isVisible {
                    self.indexingProgress = progress
                    lastPublish = now
                    lastPhase = progress.phase

                    let fraction: Double? = progress.itemsTotal > 0
                        ? Double(progress.itemsComplete) / Double(progress.itemsTotal) : nil

                    if let idx = self.folders.firstIndex(where: { $0.path == url.path }) {
                        self.folders[idx] = FolderItem(
                            id: self.folders[idx].id,
                            displayName: url.lastPathComponent, path: url.path,
                            driveType: self.folders[idx].driveType,
                            imageCount: progress.itemsComplete,
                            pairCount: self.folders[idx].pairCount,
                            isIndexing: !(isFolderReady || isStreamDone),
                            indexingFraction: (isFolderReady || isStreamDone) ? nil : fraction
                        )
                    }
                }

                if isFolderReady {
                    // Folder view is ready — unblock the UI and refresh sidebar counts.
                    self.isIndexing = false
                    await self.refreshFolders()
                }
                // Reveal the background chip only once the engine emits its first
                // explicit background phase, so its label is correct on first appearance.
                // (Showing it on .complete would flash "Setting up…" for the sub-second
                // vector-load before cross-folder scoring starts.) .scoringCrossFolder is
                // emitted only when there is genuine cross-folder work; .backgroundScoring
                // covers the setup/role-generation tail and the single-folder case.
                if progress.phase == .scoringCrossFolder {
                    self.isBackgroundScoring = true
                    self.isScoringCrossFolder = true
                } else if progress.phase == .backgroundScoring {
                    self.isBackgroundScoring = true
                    self.isScoringCrossFolder = false
                }
                if isStreamDone {
                    // Phase 2 complete (or error) — refresh so All view picks up cross-folder pairs.
                    self.isBackgroundScoring = false
                    self.isScoringCrossFolder = false
                    await self.refreshFolders()
                    break
                }
            }

            // Failsafe: ensure state is cleared if the stream ends unexpectedly.
            self.isIndexing = false
            self.isBackgroundScoring = false
            self.isScoringCrossFolder = false
            await self.refreshFolders()
        }
    }

    // MARK: - Remove folder

    func removeFolder(id: Int) {
        guard let qs = queryService else { return }
        Task {
            try? await qs.removeFolder(id: Int64(id))
            await self.refreshFolders()
        }
        folders.removeAll { $0.id == id }
        hasAnyFolders = !folders.isEmpty
    }

    // MARK: - Fetch pairs

    func fetchPairs(
        folderID: Int64? = nil, collectionID: Int64? = nil, anchorImageID: Int64? = nil
    ) async -> [DisplayPair] {
        guard let qs = queryService else { return [] }
        do {
            // Fetch a larger pool so the per-image cap has enough to work with.
            // The cap and re-weighting together can shrink 750 down significantly,
            // so we fetch 2000 from the DB and trim after capping.
            // Anchor queries use 500 — the displayLimit trim below is inside
            // `if anchorImageID == nil`, so the DB limit IS the display cap for
            // anchor; 200 was too small for hub images (400+ pairs). #86
            let dbLimit = anchorImageID != nil ? 500 : 2000
            let displayLimit = anchorImageID != nil ? 200 : 750
            let results: [PairQueryResult] = try await qs.fetchPairs(
                folderID: folderID, collectionID: collectionID,
                anchorImageID: anchorImageID, limit: dbLimit
            )
            // Apply display-time geometric scoring: distinctiveness multiplier (v6+)
            // followed by hard floor gating from slider settings.
            // Pre-v5 pairs fall back to stored geometricScore; pre-v6 pairs skip the
            // multiplier but still get floor gating.
            let peakFloor = settings.edgePeakednessFloor
            let varFloor  = settings.gridVarianceFloor
            var pairs = results.map { result in
                let adjGeo = adjustedGeometric(result, peakFloor: peakFloor, varFloor: varFloor)
                return convertToPair(result, adjustedGeometricScore: adjGeo)
            }

            // Thematic threshold filter — only applied when threshold > 0
            if settings.minThematicScore > 0 {
                pairs = pairs.filter { $0.thematicScore >= settings.minThematicScore }
            }

            // Re-sort by display-time composite (weights × adjusted component scores).
            // compositeScore in each DisplayPair already reflects current weights and
            // gating, so this sort is always meaningful and drives displayedPairs correctly.
            pairs.sort { $0.compositeScore > $1.compositeScore }

            // Per-image cap: prevent any single image from dominating.
            if anchorImageID == nil {
                let perImageCap = 15
                var imageCounts = [Int: Int]()
                pairs = pairs.filter { pair in
                    let countA = imageCounts[pair.imageAID, default: 0]
                    let countB = imageCounts[pair.imageBID, default: 0]
                    guard countA < perImageCap && countB < perImageCap else { return false }
                    imageCounts[pair.imageAID, default: 0] += 1
                    imageCounts[pair.imageBID, default: 0] += 1
                    return true
                }
                // Trim to display limit after cap
                if pairs.count > displayLimit {
                    pairs = Array(pairs.prefix(displayLimit))
                }
            }

            return pairs
        } catch {
            print("fetchPairs error: \(error)")
            return []
        }
    }

    // MARK: - Representative pair fetch (grid)

    /// Fetches one representative pair per image (top-1 by sort order from either side),
    /// applies display-time geometric adjustments, enforces a hard cap of 2 appearances
    /// per image, and paginates from an in-memory cache.
    ///
    /// Page 0 fetches all candidates from DB, applies cap-2, and populates the cache.
    /// Pages 1+ slice from the cache — no additional DB round-trip.
    /// This avoids the previous bug where SQL LIMIT 150 was applied before cap-2,
    /// leaving hub images dominating the first page and ~44 pairs surviving.
    ///
    /// On page 0, also refreshes `imagePairCounts` for the given folder context.
    func fetchRepresentativePairs(
        folderID: Int64? = nil,
        collectionID: Int64? = nil,
        sortOrder: PairSortOrder = .composite,
        page: Int = 0
    ) async -> [DisplayPair] {
        guard !Task.isCancelled else { return [] }
        guard let qs = queryService else { return [] }
        loadGeneration += 1
        let myGeneration = loadGeneration
        let pageSize = 150

        if page == 0 {
            do {
                // Both DB calls run on a detached task so they never queue behind an
                // in-flight actor-isolated query (nonisolated methods, DatabasePool
                // concurrent reads via WAL). The map + sort + cap-2 dedup also run
                // in the detached block — @MainActor values are captured as locals
                // before entering the closure so self is never touched inside it.
                // Stale results are discarded by the generation counter on return.
                let sortColumn = sortOrder.dbColumn
                let capturedWeights     = settings.weights
                let capturedPeakFloor   = settings.edgePeakednessFloor
                let capturedVarFloor    = settings.gridVarianceFloor
                let capturedMinThematic = settings.minThematicScore
                let capturedThumbnailBase = thumbnailBaseURL

                let (pairCounts, pairs) = try await Task.detached(priority: .userInitiated) {
                    let c = try qs.fetchImagePairCounts(folderID: folderID, collectionID: collectionID)
                    let r = try qs.fetchRepresentativePairs(folderID: folderID, collectionID: collectionID, sortColumn: sortColumn)
                    let pairCountMap = Dictionary(uniqueKeysWithValues: c.map { (Int($0.key), $0.value) })
                    var mapped = r.map { result -> DisplayPair in
                        let adjGeo = adjustedGeometricFree(result, peakFloor: capturedPeakFloor, varFloor: capturedVarFloor)
                        return convertToPairFree(result, adjustedGeometricScore: adjGeo,
                                                 weights: capturedWeights, pairCounts: pairCountMap,
                                                 thumbnailBase: capturedThumbnailBase)
                    }
                    if capturedMinThematic > 0 {
                        mapped = mapped.filter { $0.thematicScore >= capturedMinThematic }
                    }
                    mapped.sort(by: pairSortComparator(for: sortOrder))
                    // Collection fast-path: curated sets skip cap-2 deduplication.
                    if collectionID == nil {
                        mapped = applyCap2Free(mapped)
                        mapped.sort(by: pairSortComparator(for: sortOrder))
                    }
                    return (pairCountMap, mapped)
                }.value
                guard loadGeneration == myGeneration else { return [] }
                imagePairCounts = pairCounts
                representativePairsCache = pairs
                representativePairsCacheKey = (folderID, collectionID, sortOrder.dbColumn)
            } catch {
                print("fetchRepresentativePairs error: \(error)")
                representativePairsCache = []
                representativePairsCacheKey = (nil, nil, "")
            }
        }

        // Reject the slice if the cache belongs to a different context.
        let expectedKey = (folderID, collectionID, sortOrder.dbColumn)
        guard representativePairsCacheKey.folderID == expectedKey.0,
              representativePairsCacheKey.collectionID == expectedKey.1,
              representativePairsCacheKey.sortColumn == expectedKey.2 else { return [] }

        // Slice the requested page from the cache.
        let start = page * pageSize
        guard start < representativePairsCache.count else { return [] }
        return Array(representativePairsCache[start..<min(start + pageSize, representativePairsCache.count)])
    }

    // MARK: - Progressive pair streaming (page 0)

    /// Streams page-0 pairs progressively as chunks arrive from the DB.
    ///
    /// Each yield is a batch of accepted pairs (pass-1 greedy accepts arrive per
    /// 20-row chunk; pass-2 orphan-cover pairs arrive in a final batch). The
    /// consumer can append each batch to the grid array immediately so SwiftUI
    /// renders incrementally. After the stream finishes, `representativePairsCache`
    /// is updated on @MainActor for `loadMorePairs` compatibility.
    ///
    /// All @MainActor-isolated values are captured as locals before the detached
    /// task starts; self is never accessed inside the closure.
    func streamPage0Pairs(
        folderID: Int64?, collectionID: Int64?, sortOrder: PairSortOrder,
        triggerThematicPass: Bool = true
    ) -> AsyncStream<[DisplayPair]> {
        guard let qs = queryService else { return AsyncStream { $0.finish() } }

        loadGeneration += 1
        let myGeneration = loadGeneration
        let capturedWeights         = settings.weights
        let capturedPeakFloor       = settings.edgePeakednessFloor
        let capturedVarFloor        = settings.gridVarianceFloor
        let capturedMinThematic     = settings.minThematicScore
        let capturedThumbnailBase   = thumbnailBaseURL
        let capturedTriggerThematic = triggerThematicPass
        let sortColumn = sortOrder.dbColumn

        return AsyncStream { continuation in
            let innerTask = Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    // fetchImagePairCounts runs concurrently with the pair cursor.
                    // DatabasePool WAL allows concurrent readers, so both queries
                    // execute in parallel. Counts are awaited after streaming so
                    // they don't block the first pair from appearing.
                    let countsTask = Task.detached(priority: .userInitiated) {
                        try qs.fetchImagePairCounts(folderID: folderID, collectionID: collectionID)
                    }

                    // Stream rows via GRDB cursor. SQLite walks idx_pairs_score in
                    // descending order and emits matching rows as it goes — the first
                    // 20-row chunk arrives within milliseconds without waiting for the
                    // full result set. pairCounts are not yet available (counts run
                    // concurrently), so pairCountA/B = 0 for the current load;
                    // imagePairCounts is updated on @MainActor after streaming.
                    var seenImages = Set<Int>()
                    var pass1Rejected: [DisplayPair] = []
                    var allAccepted: [DisplayPair] = []

                    try qs.streamRepresentativePairs(
                        folderID: folderID, collectionID: collectionID,
                        sortColumn: sortColumn, chunkSize: 20
                    ) { rawChunk in
                        guard !Task.isCancelled else { throw CancellationError() }

                        let converted = rawChunk.compactMap { result -> DisplayPair? in
                            let adjGeo = adjustedGeometricFree(result, peakFloor: capturedPeakFloor, varFloor: capturedVarFloor)
                            let pair = convertToPairFree(result, adjustedGeometricScore: adjGeo,
                                                         weights: capturedWeights, pairCounts: [:],
                                                         thumbnailBase: capturedThumbnailBase)
                            if capturedMinThematic > 0 && pair.thematicScore < capturedMinThematic { return nil }
                            return pair
                        }

                        if collectionID == nil {
                            // Incremental pass-1: greedy gate using running seenImages across chunks.
                            var accepted: [DisplayPair] = []
                            for pair in converted {
                                if !seenImages.contains(pair.imageAID) && !seenImages.contains(pair.imageBID) {
                                    accepted.append(pair)
                                    seenImages.insert(pair.imageAID)
                                    seenImages.insert(pair.imageBID)
                                } else {
                                    pass1Rejected.append(pair)
                                }
                            }
                            if !accepted.isEmpty { continuation.yield(accepted) }
                            allAccepted.append(contentsOf: accepted)
                        } else {
                            // Collection fast-path: no cap-2.
                            continuation.yield(converted)
                            allAccepted.append(contentsOf: converted)
                        }
                    }

                    // Pass-2: cover images left unrepresented after pass-1.
                    if collectionID == nil, !Task.isCancelled {
                        let pass2 = applyPass2Free(pass1Rejected, seenImages: seenImages)
                        if !pass2.isEmpty {
                            continuation.yield(pass2)
                            allAccepted.append(contentsOf: pass2)
                        }
                    }

                    // Await counts (ran concurrently with the cursor — likely already
                    // done by now). Silently ignore errors; missing counts just mean
                    // pairCountA/B remain 0 and badges don't show for this session.
                    let rawCounts = (try? await countsTask.value) ?? [:]
                    let pairCounts = Dictionary(uniqueKeysWithValues: rawCounts.map { (Int($0.key), $0.value) })

                    // Populate cache on @MainActor so loadMorePairs can still slice it.
                    if !Task.isCancelled {
                        let finalSorted = allAccepted.sorted(by: pairSortComparator(for: sortOrder))
                        await MainActor.run { [weak self] in
                            guard let self, self.loadGeneration == myGeneration else { return }
                            self.imagePairCounts = pairCounts
                            self.representativePairsCache = finalSorted
                            self.representativePairsCacheKey = (folderID, collectionID, sortColumn)
                            if capturedTriggerThematic { self.startThematicV2Pass() }
                        }
                    }
                } catch is CancellationError {
                    // Normal early exit — stream was cancelled by a newer navigation.
                } catch {
                    print("streamPage0Pairs error: \(error)")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in innerTask.cancel() }
        }
    }

    // MARK: - Decisions

    func saveDecision(pairID: Int64, decision: String) {
        guard let qs = queryService else { return }
        Task { try? await qs.saveDecision(pairID: pairID, decision: decision) }
    }

    func deletePair(pairID: Int64) {
        guard let qs = queryService else { return }
        Task { try? await qs.deletePairRecord(pairID: pairID) }
    }

    // MARK: - Collection management

    func fetchCollections() async -> [CollectionItem] {
        guard let qs = queryService else { return [] }
        do {
            let results = try await qs.fetchCollections()
            return results.map { CollectionItem(id: $0.id, name: $0.name, pairCount: $0.pairCount) }
        } catch {
            print("fetchCollections error: \(error)")
            return []
        }
    }

    func createCollection(name: String) async -> CollectionItem? {
        guard let qs = queryService else { return nil }
        do {
            let newID = try await qs.createCollection(name: name)
            return CollectionItem(id: Int(newID), name: name, pairCount: 0)
        } catch {
            print("createCollection error: \(error)")
            return nil
        }
    }

    func deleteCollectionFromDB(id: Int) async {
        guard let qs = queryService else { return }
        try? await qs.deleteCollection(id: Int64(id))
    }

    func renameCollectionInDB(id: Int, to name: String) async {
        guard let qs = queryService else { return }
        try? await qs.renameCollection(id: Int64(id), to: name)
    }

    func addPairToCollection(pairID: Int, collectionID: Int) async -> Bool {
        guard let qs = queryService else { return false }
        return (try? await qs.addPairToCollection(pairID: Int64(pairID), collectionID: Int64(collectionID))) ?? false
    }

    func removePairFromCollection(pairID: Int, collectionID: Int) async {
        guard let qs = queryService else { return }
        try? await qs.removePairFromCollection(pairID: Int64(pairID), collectionID: Int64(collectionID))
    }

    // MARK: - Thumbnail

    func thumbnailURL(for path: String?) -> URL? {
        guard let path = path, !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return thumbnailBaseURL.appendingPathComponent(path)
    }

    // MARK: - Security-scoped folder access (for export)

    /// Resolves the security-scoped bookmark for the indexed folder that contains
    /// `imagePath`, starts accessing it, and returns the folder URL.
    ///
    /// Returns `nil` if no bookmark has been stored for the folder yet (e.g. folders
    /// indexed before this version of the app). In that case the caller should prompt
    /// the user to re-select the folder via `NSOpenPanel`.
    ///
    /// **The caller is responsible for calling `stopAccessingSecurityScopedResource()`
    /// on the returned URL when the file operation is complete.**
    func startAccessingFolder(for imagePath: String) -> URL? {
        for folder in folders {
            guard imagePath.hasPrefix(folder.path) else { continue }
            guard let url = FolderBookmarks.resolve(folderPath: folder.path) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            return url
        }
        return nil
    }

    /// The set of indexed folder paths, used by export to match image paths to
    /// their parent folder when no bookmark has been found yet.
    var indexedFolderPaths: [String] { folders.map(\.path) }

    // MARK: - Image paths (for export)

    /// Returns on-disk paths for both images in a pair. Used by export to load full-resolution source files.
    func imagePaths(imageAID: Int, imageBID: Int) async -> (String, String)? {
        guard let qs = queryService else { return nil }
        guard let result = try? await qs.fetchImagePaths(
            imageAID: Int64(imageAID), imageBID: Int64(imageBID)
        ) else { return nil }
        return (result.pathA, result.pathB)
    }

    // MARK: - CLIP model bookmark

    var hasModelBookmark: Bool { ModelBookmark.hasBookmark }

    func storeModelBookmark(url: URL) {
        do {
            try ModelBookmark.store(url: url)
            // If already running real CLIP, no need to rebuild
            guard !hasRealCLIP, let db else {
                print("CLIP: bookmark stored, skipping rebuild (already loaded)")
                return
            }
            startEngineBuild(db: db)
        } catch {
            print("CLIP: failed to store bookmark — \(error)")
        }
    }

    // MARK: - Private

    /// Starts a CLIP engine build, cancelling any previous in-flight build first.
    private func startEngineBuild(db: DatabaseManager) {
        engineBuildTask?.cancel()
        engineBuildTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let clip = await self.buildCLIPEngine()
            let captioning = await self.buildCaptioningEngine()
            let roleExtraction = await self.buildRoleExtractionEngine()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.indexingEngine = IndexingEngine(
                    db: db, clipEngine: clip,
                    captioningEngine: captioning,
                    roleExtractionEngine: roleExtraction
                )
            }
        }
    }

    private func buildRoleExtractionEngine() async -> any RoleExtractionEngine {
        // Role extraction (#102) needs qwen2.5:14b-instruct. If absent, use the mock,
        // which returns empty profiles — Phase 3.55 skips writing those, so the
        // `roleProfile IS NULL` sentinel stays intact for a later run once the model
        // is pulled (no poisoning).
        if await OllamaRoleExtractionEngine.isAvailable() {
            print("ROLE: ollama + qwen2.5:14b-instruct available")
            return OllamaRoleExtractionEngine()
        }
        print("ROLE: qwen2.5:14b-instruct not available — role extraction disabled. Run: ollama pull qwen2.5:14b-instruct")
        return MockRoleExtractionEngine()
    }

    private func buildCaptioningEngine() async -> any CaptioningEngine {
        let available = await OllamaCaptioningEngine.isAvailable()
        await MainActor.run { self.captioningAvailable = available }
        if available {
            print("CAPTION: ollama + qwen2.5vl-caption available")
            return OllamaCaptioningEngine()
        }
        print("CAPTION: ollama not available — captioning disabled. Install ollama and run: ollama pull qwen2.5vl:7b && ollama create qwen2.5vl-caption -f ConjunctEngine/Modelfile")
        return MockCaptioningEngine()
    }

    private func refreshFolders() async {
        guard let qs = queryService else { return }
        do {
            let results: [FolderQueryResult] = try await qs.fetchFolders()
            let dbFolders = results.map { r in
                FolderItem(
                    id: Int(r.id), displayName: r.displayName, path: r.path,
                    driveType: folderDriveTypeFromString(r.driveType),
                    imageCount: r.imageCount, pairCount: r.pairCount,
                    isIndexing: false, indexingFraction: nil
                )
            }
            var merged = dbFolders
            for existing in folders where existing.isIndexing {
                if !merged.contains(where: { $0.path == existing.path }) {
                    merged.append(existing)
                }
            }
            folders = merged
            hasAnyFolders = !folders.isEmpty
        } catch {
            print("refreshFolders error: \(error)")
        }
    }

    /// Compute the display-time geometric score.
    ///
    /// Two layers of modulation are applied in order:
    /// 1. Continuous distinctiveness multiplier — √(norm_A × norm_B) for each sub-signal.
    ///    Both images must be geometrically interesting for the pair to earn full credit.
    /// 2. Hard floor gate — if even the better image falls below the slider threshold,
    ///    discount that sub-signal an additional 40%/50%. Complementary to the multiplier:
    ///    the multiplier penalises when both are flat; the floor catches cases where the
    ///    stronger image still isn't strong enough by the user's chosen standard.
    ///
    /// Falls back to stored geometricScore for pre-v5 pairs (nil raw scores) or
    /// pre-v6 pairs (nil multipliers, applies floor gating only).
    private func adjustedGeometric(
        _ result: PairQueryResult,
        peakFloor: Float,
        varFloor: Float
    ) -> Float {
        guard let rawEdge = result.rawEdgeSim,
              let rawGrid = result.rawGridSim else {
            return Float(result.geometricScore)   // pre-v5 fallback
        }

        // Apply the distinctiveness multiplier when available (v6+), else use raw values.
        let edgeMult = result.edgePeakednessMult.map { Float($0) } ?? 1.0
        let varMult  = result.gridVarianceMult.map   { Float($0) } ?? 1.0
        var edgeSim  = Float(rawEdge) * edgeMult
        var gridSim  = Float(rawGrid) * varMult

        // Hard floor gate on top — uses the max of A and B so one strong image can
        // keep the pair out of the penalty zone even if the other is weaker.
        if let maxPeak = result.maxEdgePeakedness, Float(maxPeak) < peakFloor { edgeSim *= 0.40 }
        if let maxVar  = result.maxGridVariance,   Float(maxVar)  < varFloor  { gridSim *= 0.50 }

        return (edgeSim + gridSim) / 2
    }

    private func convertToPair(_ r: PairQueryResult, adjustedGeometricScore: Float) -> DisplayPair {
        let geoScore = adjustedGeometricScore
        // Use thematicV2Score when available (LLM-based pair scorer), falling back to
        // the cluster-based thematicScore. See decision #82. A REJECTED role-join
        // hypothesis (#102) returns thematicV2Score == 0; that verdict concerns the
        // specific role connection, not the pair's overall thematic value, so it must
        // not demote the pair below its cluster thematicScore — fall back in that case.
        let effectiveThematic: Float = {
            if r.roleHypothesis != nil, r.thematicV2Score == 0 { return Float(r.thematicScore) }
            return Float(r.thematicV2Score ?? r.thematicScore)
        }()
        let modality: PairingModality
        // selectedFor records the actual topK path at scoring time; use it directly
        // when available. NULL (pre-v8 rows) fall back to post-hoc score comparison.
        if r.selectedFor == "thematic" {
            modality = .thematic
        } else if r.selectedFor == "aesthetic" {
            modality = .aesthetic
        } else if Double(effectiveThematic) >= 0.25 && Double(effectiveThematic) > Double(geoScore) {
            modality = .thematic
        } else if Double(geoScore) >= r.aestheticScore {
            modality = .geometric
        } else {
            modality = .aesthetic
        }

        let decision: PairDecision
        switch r.userDecision {
        case "liked":    decision = .liked
        case "rejected": decision = .rejected
        case "deleted":  decision = .deleted
        default:         decision = .none
        }

        // Compute a display-time composite using the adjusted geometric score and
        // current weights. This is what displayedPairs sorts by, so all settings
        // sliders (weights + gating floors) visibly affect sort order.
        let w = settings.weights
        // Replay temporal penalty so display sort matches scorer intent.
        // captureDateA/B are fetched by both query functions; no schema change needed.
        // NOTE: captureDate is stored as INTEGER in SQLite; GRDB coercion to Double
        // required explicit Int64→Double handling in QueryService (backlog #26 fix).
        let temporalPenalty: Float = {
            guard let a = r.captureDateA, let b = r.captureDateB else { return 1.0 }
            let gap = abs(a.timeIntervalSince(b))
            if gap <= 30  { return 0.40 }
            if gap <= 60  { return 0.55 }
            if gap <= 120 { return 0.75 }
            if gap <= 300 { return 0.90 }
            return 1.0
        }()
        let displayComposite = (Float(r.aestheticScore) * w.aesthetic
                              + geoScore               * w.geometric
                              + effectiveThematic       * w.thematic)
                              * temporalPenalty
        let peakScore = max(
            Float(r.aestheticScore),
            geoScore * 0.8,
            effectiveThematic
        ) * temporalPenalty
        // Blend peak with composite so multi-axis pairs rank above single-axis.
        // 0.6/0.4 split: single-axis excellence still surfaces, but doesn't monopolize.
        // See decision #78.
        let axisScore = 0.6 * peakScore + 0.4 * displayComposite

        return DisplayPair(
            id: Int(r.pairID), imageAID: Int(r.imageAID), imageBID: Int(r.imageBID),
            filenameA: r.filenameA, filenameB: r.filenameB,
            folderA: r.folderNameA, folderB: r.folderNameB,
            captureDateA: r.captureDateA, captureDateB: r.captureDateB,
            cameraModelA: r.cameraModelA, cameraModelB: r.cameraModelB,
            colorProfileA: r.colorProfileA, colorProfileB: r.colorProfileB,
            captionA: r.captionA, captionB: r.captionB,
            modality: modality, aestheticSubmode: r.aestheticSubmode,
            geometricSubmode: r.geometricSubmode,
            accentHueA: r.accentHueA, accentSaturationA: r.accentSaturationA,
            accentHueB: r.accentHueB, accentSaturationB: r.accentSaturationB,
            compositeScore: displayComposite, axisScore: axisScore,
            aestheticScore: Float(r.aestheticScore),
            geometricScore: geoScore, thematicScore: effectiveThematic,
            rationale: r.rationale,
            thematicV2Rationale: r.thematicV2Rationale,
            thematicV2RelationshipType: r.thematicV2RelationshipType,
            pairCountA: imagePairCounts[Int(r.imageAID), default: 0],
            pairCountB: imagePairCounts[Int(r.imageBID), default: 0],
            thumbnailURLA: thumbnailURL(for: r.thumbnailPathA),
            thumbnailURLB: thumbnailURL(for: r.thumbnailPathB),
            pathA: r.imagePathA, pathB: r.imagePathB,
            folderPathA: r.folderPathA, folderPathB: r.folderPathB,
            decision: decision
        )
    }

    private func buildCLIPEngine() async -> any CLIPInferenceEngine {
        // Resolve the bookmark on the main actor (UserDefaults access) before
        // entering the detached task which runs off-actor.
        let bookmarkURL: URL? = ModelBookmark.resolve()

        return await Task.detached(priority: .userInitiated) { [self] in
            if let url = bookmarkURL {
                _ = url.startAccessingSecurityScopedResource()
                if let engine = try? CLIPCoreMLEngine(modelURL: url) {
                    await MainActor.run { self.hasRealCLIP = true }
                    print("CLIP: loaded via bookmark from \(url.lastPathComponent)")
                    return engine as any CLIPInferenceEngine
                }
                url.stopAccessingSecurityScopedResource()
            }
            let modelName = "clip-vit-base-patch32"
            if let bundleURL = Bundle.main.url(forResource: modelName, withExtension: "mlpackage"),
               let engine = try? CLIPCoreMLEngine(modelURL: bundleURL) {
                await MainActor.run { self.hasRealCLIP = true }
                print("CLIP: loaded from app bundle")
                return engine as any CLIPInferenceEngine
            }
            print("CLIP: model not found — using MockCLIPEngine")
            return MockCLIPEngine(simulatedLatencyMs: 0) as any CLIPInferenceEngine
        }.value
    }

    /// Cancels any running ThematicV2 pass and starts a fresh one.
    /// Called after page-0 pairs load so the pass runs against the same pair set the user is viewing.
    /// Runs at .background priority — Ollama inference is the bottleneck, not CPU priority.
    /// The GRDB Pool.swift priority inversion warning (decision #87) remains; fixing it cleanly
    /// requires GRDB's async-await API, which is a larger refactor than the inversion warrants.
    private func startThematicV2Pass() {
        // If a pass is already in progress, don't cancel and restart it — sort/filter
        // changes trigger streamPage0Pairs which calls here, and we don't want each
        // navigation event to kill the running pass and start over from pair #1.
        // A new pass will start automatically the next time the grid loads after
        // the current one finishes. Explicit cancellation (e.g. on reindex) goes
        // through thematicV2PassTask?.cancel() at line ~133, which bypasses this guard.
        guard !isThematicV2Running else { return }
        guard let db else { return }
        // Set synchronously on @MainActor before creating the task. If isThematicV2Running
        // were set inside the detached task's first await MainActor.run instead, a second
        // call could arrive before the task body executes (due to .background scheduling
        // latency), pass the guard above, cancel the first task, and create a replacement —
        // leaving the cancelled task's cleanup to set isThematicV2Running = false while
        // the replacement is still initialising. See decision #87.
        isThematicV2Running = true
        thematicV2Scored = 0
        thematicV2Total = 0
        thematicV2PassTask?.cancel()
        thematicV2PassTask = Task.detached(priority: .background) { [self] in
            // Gate on model availability: if qwen2.5:14b-instruct isn't pulled, every
            // request 404s and the pass would abort after 3 consecutive failures. Skip
            // cleanly instead (decision #102).
            guard await ThematicScorerV2.isAvailable() else {
                print("ThematicV2: qwen2.5:14b-instruct not available — pass skipped. Run: ollama pull qwen2.5:14b-instruct")
                await MainActor.run { self.isThematicV2Running = false }
                return
            }
            let pass = ThematicV2BackgroundPass(db: db)
            await pass.run { [self] scored, total in
                await MainActor.run {
                    self.thematicV2Scored = scored
                    self.thematicV2Total = total
                    if scored % EngineController.kThematicV2BatchSize == 0 {
                        self.thematicV2BatchCount += 1
                    }
                }
            }
            await MainActor.run { self.isThematicV2Running = false }
        }
    }

    private func detectDriveType(_ url: URL) -> FolderItem.DriveType {
        if url.path.hasPrefix("/Volumes") { return .external }
        return .internal
    }

    private func folderDriveTypeFromString(_ raw: String?) -> FolderItem.DriveType {
        switch raw {
        case "external": return .external
        case "nas":      return .nas
        default:         return .internal
        }
    }
}


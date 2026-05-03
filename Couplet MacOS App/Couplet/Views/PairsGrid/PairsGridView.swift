import SwiftUI
import ConjunctEngine
import UniformTypeIdentifiers

struct PairsGridView: View {

    @EnvironmentObject var engine: EngineController
    @ObservedObject var gridVM: PairsGridViewModel
    @ObservedObject var libraryVM: LibraryViewModel
    @Environment(SettingsStore.self) private var settings
    @State private var completionCardDismissed = false

    // Fixed row height prevents tiles from collapsing/expanding during window resize.
    // The tile height = 120px thumbnail + ~36px metadata strip.
    private static let tileHeight: CGFloat = 160
    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 380), spacing: 12)]

    private var currentFolderID: Int64? { libraryVM.selectedFolderID.map { Int64($0) } }
    private var currentCollectionID: Int64? { libraryVM.selectedCollectionID.map { Int64($0) } }

    var body: some View {
        contentView
    }

    private var contentView: some View {
        VStack(spacing: 0) {
            if gridVM.isAnchored {
                gridAnchorStrip
            }

            countHeader

            if gridVM.isLoading {
                Spacer()
                ProgressView("Loading pairs…").foregroundColor(Color.appMutedForeground)
                Spacer()
            } else if gridVM.displayedPairs.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .background(Color.appBackground)
        // Scoring pill + indexing card stacked at bottom-trailing
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                if engine.isBackgroundScoring {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                        Text("Scoring cross-folder pairs")
                            .font(.system(size: 11))
                            .foregroundColor(Color.appMutedForeground)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.appCard)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.appBorder, lineWidth: 1))
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                }

                if engine.isIndexing || (shouldShowCompletionCard && !completionCardDismissed) {
                    if let progress = engine.indexingProgress {
                        IndexingProgressCard(progress: progress) {
                            completionCardDismissed = true
                        }
                        .transition(.opacity.animation(.easeOut(duration: 0.3)))
                    }
                }
            }
            .padding(20)
        }
        .onChange(of: libraryVM.selectedFolderID) { _, folderID in
            Task { @MainActor in
                gridVM.loadPairs(from: engine, folderID: folderID.map { Int64($0) })
            }
        }
        .onChange(of: libraryVM.selectedCollectionID) { _, cid in
            Task { @MainActor in
                gridVM.loadPairs(from: engine, collectionID: cid.map { Int64($0) })
            }
        }
        .onChange(of: engine.isIndexing) { _, indexing in
            if indexing { completionCardDismissed = false }
            guard !indexing else { return }
            Task { @MainActor in
                gridVM.loadPairs(from: engine, folderID: currentFolderID, collectionID: currentCollectionID)
            }
        }
        .onChange(of: engine.isBackgroundScoring) { _, scoring in
            guard !scoring else { return }
            // Phase 2 done — reload so All view picks up cross-folder pairs.
            Task { @MainActor in
                gridVM.loadPairs(from: engine, folderID: currentFolderID, collectionID: currentCollectionID)
            }
        }
        .onAppear {
            Task { @MainActor in
                if !engine.folders.isEmpty {
                    gridVM.loadPairs(from: engine)
                }
            }
        }
        .onChange(of: engine.folders.count) { _, count in
            guard count > 0, !gridVM.isLoading, gridVM.pairCount == 0 else { return }
            Task { @MainActor in
                gridVM.loadPairs(from: engine, folderID: currentFolderID, collectionID: currentCollectionID)
            }
        }
        .onChange(of: settings.weights) { _, _ in
            Task { @MainActor in
                gridVM.loadPairs(from: engine, folderID: currentFolderID, collectionID: currentCollectionID)
            }
        }
        .onChange(of: settings.minThematicScore) { _, _ in
            Task { @MainActor in
                gridVM.loadPairs(from: engine, folderID: currentFolderID, collectionID: currentCollectionID)
            }
        }
        .onChange(of: settings.edgePeakednessFloor) { _, _ in
            Task { @MainActor in
                gridVM.loadPairs(from: engine, folderID: currentFolderID, collectionID: currentCollectionID)
            }
        }
        .onChange(of: settings.gridVarianceFloor) { _, _ in
            Task { @MainActor in
                gridVM.loadPairs(from: engine, folderID: currentFolderID, collectionID: currentCollectionID)
            }
        }
        .onChange(of: gridVM.sortOrder) { _, _ in
            Task { @MainActor in
                gridVM.loadPairs(from: engine, folderID: currentFolderID, collectionID: currentCollectionID)
            }
        }
        .onAppear { gridVM.hideSequential = settings.hideSequential }
        .onChange(of: settings.hideSequential) { _, new in gridVM.hideSequential = new }
    }

    private var shouldShowCompletionCard: Bool {
        engine.indexingProgress?.phase == .complete
    }

    // MARK: - Anchor strip

    private var gridAnchorStrip: some View {
        HStack(spacing: 10) {
            Image(systemName: "scope").font(.system(size: 12)).foregroundColor(Color.appMutedForeground)
            Text("Pairs for").font(.system(size: 12)).foregroundColor(Color.appMutedForeground)
            Text(gridVM.anchorFilename ?? "")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.appForeground)
                .lineLimit(1)
            Spacer()
            Button("Release Anchor") { gridVM.releaseAnchor() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Color.appMutedForeground)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Color.appSecondary.opacity(0.5))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.appBorder).frame(height: 1)
        }
    }

    // MARK: - Count header

    private var countHeader: some View {
        HStack {
            Text("\(gridVM.pairCount) pair\(gridVM.pairCount == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundColor(Color.appMutedForeground)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)
    }

    // MARK: - Grid

    private var grid: some View {
        let pairs = gridVM.displayedPairs
        let fid = currentFolderID
        let cid = currentCollectionID
        let activeCID = libraryVM.selectedCollectionID
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(pairs) { pair in
                    PairTileView(
                        pair: pair,
                        onLike:   { gridVM.likePair(id: pair.id, engine: engine) },
                        onReject: { gridVM.rejectPair(id: pair.id, engine: engine) },
                        onDelete: { gridVM.deletePair(id: pair.id, engine: engine) },
                        onOpen:   { gridVM.openLightbox(pairID: pair.id) },
                        onRemoveFromCollection: activeCID == nil ? nil : {
                            guard let collectionID = activeCID else { return }
                            Task {
                                await engine.removePairFromCollection(
                                    pairID: pair.id, collectionID: collectionID
                                )
                                gridVM.removePair(id: pair.id)
                                libraryVM.refreshPairCount(forCollection: collectionID, delta: -1)
                            }
                        }
                    )
                    .frame(height: Self.tileHeight)
                    .opacity(pair.decision == .rejected ? 0.4 : 1.0)
                    .animation(.easeOut(duration: 0.15), value: pair.decision)
                    .onDrag(
                        { NSItemProvider(object: "\(pair.id)" as NSString) },
                        preview: { PairDragPreview(pair: pair) }
                    )
                    if pair.id == pairs.last?.id {
                        Color.clear.frame(height: 1).onAppear {
                            gridVM.loadMorePairs(from: engine, folderID: fid, collectionID: cid)
                        }
                    }
                }
            }
            .padding(20)

            if gridVM.isLoadingMore {
                ProgressView()
                    .padding(.vertical, 12)
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            if engine.isIndexing {
                Text("👯").font(.system(size: 36))
                Text("Indexing pairs")
                    .foregroundColor(Color.appMutedForeground)
                Text("I'll load your pairs after scoring them. Hang tight.")
                    .font(.caption)
                    .foregroundColor(Color.appMutedForeground.opacity(0.6))
                    .multilineTextAlignment(.center)
            } else if gridVM.hasActiveFilters {
                Image(systemName: "rectangle.2.swap")
                    .font(.system(size: 40)).foregroundColor(Color.appMutedForeground.opacity(0.4))
                Text("No pairs match these filters").foregroundColor(Color.appMutedForeground)
                Button("Clear filters") { gridVM.clearFilters() }
                    .buttonStyle(.plain).foregroundColor(Color.appMutedForeground)
            } else if libraryVM.selectedCollectionID != nil {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 40)).foregroundColor(Color.appMutedForeground.opacity(0.4))
                Text("No pairs in this collection").foregroundColor(Color.appMutedForeground)
                Text("Drag pairs from the grid or use \u{201C}Add to Collection\u{201D} in the lightbox")
                    .font(.caption).foregroundColor(Color.appMutedForeground.opacity(0.6))
                    .multilineTextAlignment(.center)
            } else if engine.folders.isEmpty {
                Image(systemName: "rectangle.2.swap")
                    .font(.system(size: 40)).foregroundColor(Color.appMutedForeground.opacity(0.4))
                Text("No folder indexed yet").foregroundColor(Color.appMutedForeground)
                Text("Use the Add Folder button to get started")
                    .font(.caption).foregroundColor(Color.appMutedForeground.opacity(0.6))
            } else {
                Image(systemName: "rectangle.2.swap")
                    .font(.system(size: 40)).foregroundColor(Color.appMutedForeground.opacity(0.4))
                Text("No pairs found").foregroundColor(Color.appMutedForeground)
                Text("Try re-indexing or check your photo folder")
                    .font(.caption).foregroundColor(Color.appMutedForeground.opacity(0.6))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Drag preview

/// Shown as the drag ghost when a pair tile is dragged.
///
/// Images are loaded in onAppear rather than passed pre-fetched from the call site.
/// This handles the first-drag case where ThumbnailView.task hasn't yet populated
/// the cache: onAppear checks the cache first (instant), then falls back to a
/// userInitiated disk read if either image is missing. Because the drag preview is
/// a live SwiftUI view, the state update re-renders it with the real image within
/// ~50 ms, before the user has moved far.
///
/// Shrink animation: delay 0.4 s + 0.3 s spring = completes by ~0.7 s, well
/// within a typical drag gesture. The previous 0.9 s delay let users drop before
/// the animation fired, causing inconsistent behaviour.
private struct PairDragPreview: View {
    let pair: DisplayPair

    @State private var imageA: NSImage?
    @State private var imageB: NSImage?
    @State private var scale: CGFloat = 1.0

    private let previewWidth: CGFloat = 280
    private let previewHeight: CGFloat = 110

    var body: some View {
        HStack(spacing: 2) {
            pane(imageA, color: pair.colorA)
            pane(imageB, color: pair.colorB)
        }
        .frame(width: previewWidth, height: previewHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .scaleEffect(scale, anchor: .center)
        .onAppear {
            // Fast path: already in cache from the visible tile
            imageA = pair.thumbnailURLA.flatMap { ThumbnailCache.shared.image(for: $0) }
            imageB = pair.thumbnailURLB.flatMap { ThumbnailCache.shared.image(for: $0) }

            // Slow path: first drag before cache is warm — load from disk directly.
            // Local JPEG thumbnails are small (~30–80 KB), so this takes < 50 ms.
            if imageA == nil || imageB == nil {
                let urlA = pair.thumbnailURLA
                let urlB = pair.thumbnailURLB
                Task.detached(priority: .userInitiated) {
                    let a: NSImage? = urlA.flatMap { NSImage(contentsOf: $0) }
                    let b: NSImage? = urlB.flatMap { NSImage(contentsOf: $0) }
                    await MainActor.run {
                        if let a { imageA = a }
                        if let b { imageB = b }
                    }
                }
            }

            withAnimation(.easeOut(duration: 0.3).delay(0.4)) {
                scale = 0.6
            }
        }
    }

    private func pane(_ image: NSImage?, color: NSColor) -> some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(nsColor: color)
            }
        }
        .frame(width: (previewWidth - 2) / 2, height: previewHeight)
        .clipped()
    }
}

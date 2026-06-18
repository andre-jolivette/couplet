import SwiftUI
import ConjunctEngine
import UniformTypeIdentifiers

struct PairsGridView: View {

    @EnvironmentObject var engine: EngineController
    @ObservedObject var gridVM: PairsGridViewModel
    @ObservedObject var libraryVM: LibraryViewModel
    @Environment(SettingsStore.self) private var settings
    @State private var completionCardDismissed = false
    @State private var exportingPair: DisplayPair? = nil
    var onLikedCountChange: ((Int) -> Void)? = nil

    // Fixed row height prevents tiles from collapsing/expanding during window resize.
    // The tile height = 120px thumbnail + ~36px metadata strip.
    private static let tileHeight: CGFloat = 160
    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 380), spacing: 12)]

    private var currentFolderID: Int64? { libraryVM.selectedFolderID.map { Int64($0) } }
    private var currentCollectionID: Int64? { libraryVM.selectedCollectionID.map { Int64($0) } }

    var body: some View {
        contentView
            .onChange(of: libraryVM.selectedFolderID) { _, _ in reloadPairs() }
            .onChange(of: libraryVM.selectedCollectionID) { _, _ in reloadPairs() }
            .onChange(of: engine.isIndexing) { _, indexing in
                if indexing { completionCardDismissed = false }
                guard !indexing else { return }
                reloadPairs()
            }
            .onChange(of: engine.isBackgroundScoring) { _, scoring in
                guard !scoring else { return }
                reloadPairs()
            }
            .onChange(of: engine.isThematicV2Running) { _, running in
                guard !running else { return }
                // Pass finished — silent refresh to surface any final scored pairs
                // without wiping the grid. silentRefresh uses triggerThematicPass: false
                // so it won't restart the pass.
                let fid = currentFolderID
                let cid = currentCollectionID
                Task { @MainActor in
                    gridVM.silentRefresh(from: engine, folderID: fid, collectionID: cid)
                }
            }
            .onChange(of: engine.thematicV2BatchCount) { _, _ in
                // Silently refresh the grid each time a new batch of ThematicV2 scores
                // lands — pairs rearrange in place without clearing the grid or showing
                // a spinner. Uses silentRefresh rather than reloadPairs so allPairs is
                // never set to [] mid-pass.
                let fid = currentFolderID
                let cid = currentCollectionID
                Task { @MainActor in
                    gridVM.silentRefresh(from: engine, folderID: fid, collectionID: cid)
                }
            }
            .onAppear {
                Task { @MainActor in
                    if !engine.folders.isEmpty { reloadPairs() }
                }
            }
            .onChange(of: engine.folders.count) { _, count in
                guard count > 0, !gridVM.isLoading, gridVM.pairCount == 0 else { return }
                reloadPairs()
            }
            .onChange(of: settings.weights) { _, _ in reloadPairs() }
            .onChange(of: settings.minThematicScore) { _, _ in reloadPairs() }
            .onChange(of: settings.edgePeakednessFloor) { _, _ in reloadPairs() }
            .onChange(of: settings.gridVarianceFloor) { _, _ in reloadPairs() }
            .onChange(of: gridVM.sortOrder) { _, _ in reloadPairs() }
            .onAppear { gridVM.hideSequential = settings.hideSequential }
            .onChange(of: settings.hideSequential) { _, new in gridVM.hideSequential = new }
            .sheet(item: $exportingPair) { pair in
                ExportSheet(pair: pair)
            }
    }

    private func reloadPairs() {
        let fid = currentFolderID
        let cid = currentCollectionID
        Task { @MainActor in
            gridVM.loadPairs(from: engine, folderID: fid, collectionID: cid)
        }
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
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                DependencyHealthView(health: engine.dependencyHealth) {
                    await engine.checkDependencyHealth()
                }

                if engine.isThematicV2Running {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                        let total = engine.thematicV2Total
                        let label = total > 0
                            ? "Scoring thematic pairs — \(engine.thematicV2Scored) / \(total)"
                            : "Scoring thematic pairs…"
                        Text(label)
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

                if engine.isBackgroundScoring {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                        Text(engine.isScoringCrossFolder
                            ? "Scoring cross-folder pairs"
                            : "Iterating on thematic concepts")
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
                        onLike: {
                            let wasLiked = pair.decision == .liked
                            gridVM.likePair(id: pair.id, engine: engine)
                            onLikedCountChange?(wasLiked ? -1 : +1)
                        },
                        onReject: { gridVM.rejectPair(id: pair.id, engine: engine) },
                        onExport: { exportingPair = pair },
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
                        preview: {
                            // Load synchronously: cache hit is free; miss reads a
                            // ~30–80 KB local JPEG (~10 ms) — safe on any thread.
                            let imgA = pair.thumbnailURLA.flatMap {
                                ThumbnailCache.shared.image(for: $0) ?? NSImage(contentsOf: $0)
                            }
                            let imgB = pair.thumbnailURLB.flatMap {
                                ThumbnailCache.shared.image(for: $0) ?? NSImage(contentsOf: $0)
                            }
                            return PairDragPreview(
                                imageA: imgA, imageB: imgB,
                                colorA: pair.colorA, colorB: pair.colorB,
                                width: 126, height: 50
                            )
                        }
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
            } else if libraryVM.selectedCollectionID == LibraryViewModel.likedCollectionID {
                Text("💔").font(.system(size: 36))
                Text("No liked pairs, yet.").foregroundColor(Color.appMutedForeground)
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
/// Images must arrive as already-loaded NSImages — the caller resolves them
/// synchronously (cache → disk) so the very first frame has real pixels.
/// Async state updates do not reliably repaint AppKit-managed drag preview
/// windows, so we don't attempt them here.
private struct PairDragPreview: View {
    let imageA: NSImage?
    let imageB: NSImage?
    let colorA: NSColor
    let colorB: NSColor
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 2) {
            pane(imageA, color: colorA)
            pane(imageB, color: colorB)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
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
        .frame(width: (width - 2) / 2, height: height)
        .clipped()
    }
}

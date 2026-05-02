import SwiftUI
import ConjunctEngine

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

    var body: some View {
        VStack(spacing: 0) {
            FilterBarView(gridVM: gridVM)

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
                let fid = folderID.map { Int64($0) }
                gridVM.loadPairs(from: engine, folderID: fid)
            }
        }
        .onChange(of: engine.isIndexing) { _, indexing in
            if indexing { completionCardDismissed = false }
            guard !indexing else { return }
            Task { @MainActor in
                let fid = libraryVM.selectedFolderID.map { Int64($0) }
                gridVM.loadPairs(from: engine, folderID: fid)
            }
        }
        .onChange(of: engine.isBackgroundScoring) { _, scoring in
            guard !scoring else { return }
            // Phase 2 done — reload so All view picks up cross-folder pairs.
            Task { @MainActor in
                let fid = libraryVM.selectedFolderID.map { Int64($0) }
                gridVM.loadPairs(from: engine, folderID: fid)
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
                let fid = libraryVM.selectedFolderID.map { Int64($0) }
                gridVM.loadPairs(from: engine, folderID: fid)
            }
        }
        .onChange(of: settings.weights) { _, _ in
            Task { @MainActor in
                let fid = libraryVM.selectedFolderID.map { Int64($0) }
                gridVM.loadPairs(from: engine, folderID: fid)
            }
        }
        .onChange(of: settings.minThematicScore) { _, _ in
            Task { @MainActor in
                let fid = libraryVM.selectedFolderID.map { Int64($0) }
                gridVM.loadPairs(from: engine, folderID: fid)
            }
        }
        .onChange(of: settings.edgePeakednessFloor) { _, _ in
            Task { @MainActor in
                let fid = libraryVM.selectedFolderID.map { Int64($0) }
                gridVM.loadPairs(from: engine, folderID: fid)
            }
        }
        .onChange(of: settings.gridVarianceFloor) { _, _ in
            Task { @MainActor in
                let fid = libraryVM.selectedFolderID.map { Int64($0) }
                gridVM.loadPairs(from: engine, folderID: fid)
            }
        }
        .onChange(of: gridVM.sortOrder) { _, _ in
            Task { @MainActor in
                let fid = libraryVM.selectedFolderID.map { Int64($0) }
                gridVM.loadPairs(from: engine, folderID: fid)
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
        let fid = libraryVM.selectedFolderID.map { Int64($0) }
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(pairs) { pair in
                    PairTileView(
                        pair: pair,
                        onLike:   { gridVM.likePair(id: pair.id, engine: engine) },
                        onReject: { gridVM.rejectPair(id: pair.id, engine: engine) },
                        onDelete: { gridVM.deletePair(id: pair.id, engine: engine) },
                        onOpen:   { gridVM.openLightbox(pairID: pair.id) }
                    )
                    .frame(height: Self.tileHeight)
                    .opacity(pair.decision == .rejected ? 0.4 : 1.0)
                    .animation(.easeOut(duration: 0.15), value: pair.decision)
                    if pair.id == pairs.last?.id {
                        Color.clear.frame(height: 1).onAppear {
                            gridVM.loadMorePairs(from: engine, folderID: fid)
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

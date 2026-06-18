import SwiftUI

struct ContentView: View {

    @EnvironmentObject var engine: EngineController
    @StateObject private var libraryVM = LibraryViewModel()
    @StateObject private var gridVM = PairsGridViewModel()
    @StateObject private var lightboxVM = LightboxViewModel()
    @State private var showSetupSheet = false
    @State private var sidebarVisible = true
    @Environment(\.openSettings) private var openSettings

    private var lightboxOpen: Bool { gridVM.lightboxPairID != nil }

    private func dismissLightbox() {
        if lightboxVM.isAnchored,
           let id = lightboxVM.anchorImageID,
           let name = lightboxVM.anchorFilename {
            gridVM.applyAnchor(imageID: id, filename: name)
        }
        gridVM.closeLightbox()
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if sidebarVisible {
                    SidebarView(
                        libraryVM: libraryVM,
                        onAddFolder: { showSetupSheet = true },
                        onSettings: { openSettings() }
                    )
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                PairsGridView(gridVM: gridVM, libraryVM: libraryVM, onLikedCountChange: { delta in
                    libraryVM.refreshPairCount(forCollection: LibraryViewModel.likedCollectionID, delta: delta)
                })
            }
            .animation(.easeInOut(duration: 0.2), value: sidebarVisible)
            .onChange(of: libraryVM.selectedCollectionID) { _, _ in gridVM.clearFilters() }
            .sheet(isPresented: $showSetupSheet) {
                SetupSheet(isPresented: $showSetupSheet)
            }
            // WindowConfigurator sits as a zero-size background view.
            // Its viewDidMoveToWindow fires synchronously when the view
            // enters the hierarchy — before any layout pass — so the window
            // gets the correct background colour on the very first frame.
            // It also installs the sidebar toggle as a titlebar accessory
            // (next to the traffic lights, no capsule) — see CoupletTheme.swift.
            .background(WindowConfigurator(
                onToggleSidebar: {
                    withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible.toggle() }
                },
                sidebarVisible: sidebarVisible,
                lightboxOpen: lightboxOpen,
                filterBarContent: AnyView(FilterBarView(gridVM: gridVM)),
                lightboxTitlebarContent: AnyView(LightboxTitlebarView(vm: lightboxVM, onDismiss: dismissLightbox))
            ))

            // Lightbox overlay
            if lightboxOpen {
                LightboxView(
                    vm: lightboxVM,
                    allPairs: gridVM.allPairsForAnchor,
                    collections: libraryVM.collections,
                    onDecision: { id, decision in
                        let oldDecision = gridVM.allPairs.first(where: { $0.id == id })?.decision
                        gridVM.applyDecision(id: id, decision: decision, engine: engine)
                        if decision == .liked && oldDecision != .liked {
                            libraryVM.refreshPairCount(forCollection: LibraryViewModel.likedCollectionID, delta: +1)
                        } else if decision != .liked && oldDecision == .liked {
                            libraryVM.refreshPairCount(forCollection: LibraryViewModel.likedCollectionID, delta: -1)
                        }
                    },
                    onAddToCollection: { pairID, collectionID in
                        Task {
                            let inserted = await engine.addPairToCollection(pairID: pairID, collectionID: collectionID)
                            if inserted {
                                await MainActor.run {
                                    libraryVM.refreshPairCount(forCollection: collectionID, delta: +1)
                                }
                            }
                        }
                    },
                    onAnchor: { imageID in
                        let fid = libraryVM.selectedFolderID.map { Int64($0) }
                        return await engine.fetchPairs(folderID: fid, anchorImageID: Int64(imageID))
                    },
                    onDismiss: dismissLightbox
                )
                .zIndex(100)
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
        .onChange(of: gridVM.lightboxPairID) { _, pairID in
            guard pairID != nil else { return }
            lightboxVM.open(pairs: gridVM.displayedPairs, startingAt: gridVM.lightboxStartIndex)
        }
        .onAppear {
            Task { @MainActor in
                engine.initialize()
                await libraryVM.loadCollections(engine: engine)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(EngineController(settings: SettingsStore()))
        .preferredColorScheme(.dark)
        .frame(width: 1100, height: 720)
}

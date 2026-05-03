import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {

    @EnvironmentObject var engine: EngineController
    @ObservedObject var libraryVM: LibraryViewModel
    var onAddFolder: () -> Void = {}
    var onSettings: () -> Void = {}
    @State private var isAddingCollection = false
    @State private var newCollectionName = ""
    @State private var collectionToRename: CollectionItem? = nil
    @State private var renamedValue = ""
    @State private var dropTargetCollectionID: Int? = nil

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    foldersSection
                    collectionsSection
                }
                .padding(.top, 12)
            }

            settingsRow
        }
        .frame(width: 192)
        .background(Color.appBackground)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.appBorder).frame(width: 1)
        }
        .sheet(isPresented: $isAddingCollection) { addCollectionSheet }
        .popover(item: $collectionToRename) { collection in
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename Collection").font(.headline)
                TextField("Name", text: $renamedValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                HStack {
                    Spacer()
                    Button("Cancel") { collectionToRename = nil }
                    Button("Rename") {
                        libraryVM.renameCollection(id: collection.id, to: renamedValue, engine: engine)
                        collectionToRename = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(renamedValue.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Settings row (pinned to bottom)

    private var settingsRow: some View {
        Button(action: onSettings) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .frame(width: 14)
                    .font(.system(size: 13))
                    .foregroundColor(Color.appMutedForeground)
                Text("Settings")
                    .font(.system(size: 13))
                    .foregroundColor(Color.appForeground)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.appBorder).frame(height: 1)
        }
    }

    // MARK: - Folders section

    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header — matches Collections header with + button on right
            HStack {
                Text("Folders")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.2)
                    .foregroundColor(Color.appMutedForeground)
                Spacer()
                Button(action: onAddFolder) {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .foregroundColor(Color.appMutedForeground)
                }
                .buttonStyle(.plain)
                .help("Add a photo folder to index")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            // All Folders row
            SidebarRowView(
                label: "All Folders",
                systemImage: "photo.stack",
                count: nil,
                isSelected: libraryVM.selectedFolderID == nil && libraryVM.selectedCollectionID == nil,
                isIndexing: false,
                indexingFraction: nil
            )
            .onTapGesture { libraryVM.selectFolder(nil) }

            ForEach(engine.folders) { folder in
                SidebarRowView(
                    label: folder.displayName,
                    systemImage: folder.systemImage,
                    count: folder.isIndexing ? nil : folder.pairCount,
                    isSelected: libraryVM.selectedFolderID == folder.id,
                    isIndexing: folder.isIndexing,
                    indexingFraction: folder.indexingFraction
                )
                .onTapGesture {
                    guard !folder.isIndexing else { return }
                    libraryVM.selectFolder(folder.id, name: folder.displayName)
                }
                .contextMenu {
                    Button("Remove Folder", role: .destructive) {
                        engine.removeFolder(id: folder.id)
                        if libraryVM.selectedFolderID == folder.id {
                            libraryVM.selectFolder(nil)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 16)
    }

    // MARK: - Collections section

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack {
                Text("Collections")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.2)
                    .foregroundColor(Color.appMutedForeground)
                Spacer()
                Button { isAddingCollection = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .foregroundColor(Color.appMutedForeground)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            if libraryVM.collections.isEmpty {
                Text("No collections yet")
                    .font(.system(size: 12))
                    .foregroundColor(Color.appMutedForeground)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            ForEach(libraryVM.collections) { collection in
                let isDropTarget = dropTargetCollectionID == collection.id
                CollectionRowView(
                    collection: collection,
                    isSelected: libraryVM.selectedCollectionID == collection.id,
                    isDropTarget: isDropTarget
                )
                .onTapGesture { libraryVM.selectCollection(collection.id) }
                .onDrop(
                    of: [UTType.plainText],
                    isTargeted: Binding(
                        get: { dropTargetCollectionID == collection.id },
                        set: { targeting in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                dropTargetCollectionID = targeting ? collection.id : nil
                            }
                        }
                    )
                ) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                        guard let str = item as? String, let pairID = Int(str) else { return }
                        Task { @MainActor in
                            let inserted = await engine.addPairToCollection(pairID: pairID, collectionID: collection.id)
                            if inserted {
                                libraryVM.refreshPairCount(forCollection: collection.id, delta: +1)
                            }
                        }
                    }
                    return true
                }
                .contextMenu {
                    Button("Rename\u{2026}") {
                        collectionToRename = collection
                        renamedValue = collection.name
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        libraryVM.deleteCollection(id: collection.id, engine: engine)
                    }
                }
            }
        }
    }

    // MARK: - Add collection sheet

    private var addCollectionSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Collection").font(.headline)
            TextField("Collection name", text: $newCollectionName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { createCollection() }
            HStack {
                Spacer()
                Button("Cancel") { isAddingCollection = false; newCollectionName = "" }
                Button("Create") { createCollection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func createCollection() {
        let name = newCollectionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isAddingCollection = false
        newCollectionName = ""
        Task { await libraryVM.addCollection(name: name, engine: engine) }
    }
}

// MARK: - Collection drop-target row

/// Dedicated row for collection items that carries drop-target visual state.
/// When isDropTarget is true it fills with accent colour, scales up slightly,
/// and shows a "+" badge next to the count — giving the impression the row is
/// opening up to absorb the dragged pair.
private struct CollectionRowView: View {
    let collection: CollectionItem
    let isSelected: Bool
    let isDropTarget: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .frame(width: 14)
                .font(.system(size: 13))
                .foregroundColor(isDropTarget ? Color.accentColor : (isSelected ? Color.appForeground : Color.appMutedForeground))
                .scaleEffect(isDropTarget ? 1.2 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isDropTarget)

            Text(collection.name)
                .font(.system(size: 13))
                .foregroundColor(Color.appForeground)
                .lineLimit(1)

            Spacer()

            if isDropTarget {
                HStack(spacing: 1) {
                    Text("+1")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.accentColor)
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Text(collection.pairCount.formatted())
                    .font(.system(size: 11))
                    .foregroundColor(Color.appMutedForeground)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropTarget
                    ? Color.accentColor.opacity(0.12)
                    : (isSelected ? Color.appSecondary : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor.opacity(isDropTarget ? 0.55 : 0), lineWidth: 1.5)
        )
        .scaleEffect(isDropTarget ? 1.02 : 1.0, anchor: .leading)
        .animation(.spring(response: 0.2, dampingFraction: 0.65), value: isDropTarget)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Sidebar Row

private struct SidebarRowView: View {
    let label: String
    let systemImage: String
    let count: Int?
    let isSelected: Bool
    let isIndexing: Bool
    let indexingFraction: Double?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 14)
                .font(.system(size: 13))
                .foregroundColor(isSelected ? Color.appForeground : Color.appMutedForeground)

            Text(label)
                .font(.system(size: 13))
                .foregroundColor(isSelected ? Color.appForeground : Color.appForeground)
                .lineLimit(1)

            Spacer()

            if isIndexing {
                if let fraction = indexingFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 40)
                        .tint(Color.appMutedForeground)
                } else {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                }
            } else if let count {
                Text(count.formatted())
                    .font(.system(size: 11))
                    .foregroundColor(Color.appMutedForeground)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.appSecondary : Color.clear)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}

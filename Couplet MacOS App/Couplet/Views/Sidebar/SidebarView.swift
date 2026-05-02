import SwiftUI

struct SidebarView: View {

    @EnvironmentObject var engine: EngineController
    @ObservedObject var libraryVM: LibraryViewModel
    var onAddFolder: () -> Void = {}
    var onSettings: () -> Void = {}
    @State private var isAddingCollection = false
    @State private var newCollectionName = ""
    @State private var collectionToRename: CollectionItem? = nil
    @State private var renamedValue = ""

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
            Rectangle()
                .fill(Color.appBorder)
                .frame(width: 1)
                .ignoresSafeArea(.all, edges: .top)
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
                        libraryVM.renameCollection(id: collection.id, to: renamedValue)
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
                SidebarRowView(
                    label: collection.name,
                    systemImage: "rectangle.stack",
                    count: collection.pairCount,
                    isSelected: libraryVM.selectedCollectionID == collection.id,
                    isIndexing: false,
                    indexingFraction: nil
                )
                .onTapGesture { libraryVM.selectCollection(collection.id) }
                .contextMenu {
                    Button("Rename\u{2026}") {
                        collectionToRename = collection
                        renamedValue = collection.name
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        libraryVM.deleteCollection(id: collection.id)
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
        libraryVM.addCollection(name: name)
        isAddingCollection = false
        newCollectionName = ""
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

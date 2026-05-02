import Foundation
import Combine

/// Owns sidebar selection state.
/// Folder data comes from EngineController — this VM handles only selection and collections.
@MainActor
final class LibraryViewModel: ObservableObject {

    @Published var collections: [CollectionItem] = SampleData.collections
    @Published var selectedFolderID: Int? = nil
    @Published var selectedCollectionID: Int? = nil

    var selectedFolderName: String? = nil

    func selectFolder(_ id: Int?, name: String? = nil) {
        selectedFolderID = id
        selectedFolderName = name
        selectedCollectionID = nil
    }

    func selectCollection(_ id: Int?) {
        selectedCollectionID = id
        selectedFolderID = nil
        selectedFolderName = nil
    }

    func addCollection(name: String) {
        let newID = (collections.map(\.id).max() ?? 0) + 1
        collections.append(CollectionItem(id: newID, name: name, pairCount: 0))
    }

    func deleteCollection(id: Int) {
        collections.removeAll { $0.id == id }
        if selectedCollectionID == id { selectedCollectionID = nil }
    }

    func renameCollection(id: Int, to name: String) {
        guard let idx = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[idx].name = name
    }
}

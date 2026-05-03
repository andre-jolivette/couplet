import Foundation
import Combine

/// Owns sidebar selection state.
/// Folder data comes from EngineController — this VM handles only selection and collections.
@MainActor
final class LibraryViewModel: ObservableObject {

    @Published var collections: [CollectionItem] = []
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

    func loadCollections(engine: EngineController) async {
        collections = await engine.fetchCollections()
    }

    func addCollection(name: String, engine: EngineController?) async {
        guard let engine else {
            let newID = (collections.map(\.id).max() ?? 0) + 1
            collections.append(CollectionItem(id: newID, name: name, pairCount: 0))
            return
        }
        if let item = await engine.createCollection(name: name) {
            collections.append(item)
        }
    }

    func deleteCollection(id: Int, engine: EngineController?) {
        collections.removeAll { $0.id == id }
        if selectedCollectionID == id { selectedCollectionID = nil }
        guard let engine else { return }
        Task { await engine.deleteCollectionFromDB(id: id) }
    }

    func renameCollection(id: Int, to name: String, engine: EngineController?) {
        guard let idx = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[idx].name = name
        guard let engine else { return }
        Task { await engine.renameCollectionInDB(id: id, to: name) }
    }

    func refreshPairCount(forCollection id: Int, delta: Int) {
        guard let idx = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[idx].pairCount = max(0, collections[idx].pairCount + delta)
    }
}

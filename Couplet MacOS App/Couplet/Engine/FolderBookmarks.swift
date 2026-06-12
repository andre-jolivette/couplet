import Foundation

/// Persists security-scoped bookmarks for user-selected photo folders.
///
/// macOS sandboxing revokes filesystem access when the process that called
/// `startAccessingSecurityScopedResource` exits. Storing a bookmark lets the
/// app re-derive a security-scoped URL on any future launch without requiring
/// the user to pick the folder again.
///
/// Bookmarks are stored in UserDefaults keyed by folder path, so each indexed
/// folder gets exactly one entry that is refreshed whenever it goes stale.
enum FolderBookmarks {

    // MARK: - Store

    /// Persist a security-scoped bookmark for `url`.
    /// Call this immediately after the user picks a folder (while sandbox access is live).
    nonisolated static func store(url: URL) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        var dict = allBookmarks()
        dict[url.path] = data
        UserDefaults.standard.set(dict, forKey: "com.toastbrigade.Couplet.folderBookmarks")
    }

    // MARK: - Resolve

    /// Returns a security-scoped URL for `folderPath`, or nil if no bookmark exists.
    /// Access is NOT started — caller must call `startAccessingSecurityScopedResource()`.
    nonisolated static func resolve(folderPath: String) -> URL? {
        guard let data = allBookmarks()[folderPath] else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        if isStale { store(url: url) }
        return url
    }

    // MARK: - Query

    /// Returns true if a bookmark exists for `folderPath`.
    nonisolated static func hasBookmark(for folderPath: String) -> Bool {
        allBookmarks()[folderPath] != nil
    }

    // MARK: - Private

    nonisolated private static func allBookmarks() -> [String: Data] {
        (UserDefaults.standard.dictionary(forKey: "com.toastbrigade.Couplet.folderBookmarks") as? [String: Data]) ?? [:]
    }
}

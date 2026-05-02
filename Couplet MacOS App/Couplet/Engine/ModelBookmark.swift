import Foundation

/// Persists a security-scoped bookmark for the CLIP model file.
/// Once the user locates the model via the file picker, the bookmark
/// is stored in UserDefaults and resolved on every subsequent launch —
/// no picker required.
enum ModelBookmark {

    private static let key = "com.toastbrigade.Couplet.clipModelBookmark"

    // MARK: - Store

    /// Call after the user picks the model file via NSOpenPanel.
    /// Stores a security-scoped bookmark so the sandbox allows future access.
    static func store(url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: key)
    }

    // MARK: - Resolve

    /// Returns the model URL if a valid bookmark is stored, otherwise nil.
    /// Starts accessing the security-scoped resource — caller must call
    /// `stopAccessingSecurityScopedResource()` when done.
    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        // Refresh stale bookmark
        if isStale {
            try? store(url: url)
        }

        return url
    }

    // MARK: - Clear

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static var hasBookmark: Bool {
        UserDefaults.standard.data(forKey: key) != nil
    }
}

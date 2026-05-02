import SwiftUI
import AppKit

/// Progressive image view for the lightbox.
///
/// Shows the 512px thumbnail immediately (no blank state), then asynchronously
/// loads a ~2048px mid-resolution preview via MidResLoader and crossfades it in.
///
/// Only used in the main lightbox image pane — the filmstrip continues to use
/// ThumbnailView with 512px thumbnails.
struct LightboxImageView: View {

    let thumbnailURL: URL?
    let imageID: Int
    let sourcePath: String
    let folderPath: String
    var contentMode: ContentMode = .fit

    @State private var midResImage: NSImage? = nil

    var body: some View {
        ZStack {
            // Base layer: 512px thumbnail — always visible, shown immediately
            ThumbnailView(url: thumbnailURL, contentMode: contentMode)

            // Top layer: mid-res preview — crossfades in when available
            if let midRes = midResImage {
                Image(nsImage: midRes)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .task(id: imageID) {
            // Clear any previous mid-res so we don't flash a stale image while loading
            midResImage = nil

            guard !sourcePath.isEmpty, !folderPath.isEmpty else { return }

            let loaded = await MidResLoader.shared.image(
                for: imageID,
                sourcePath: sourcePath,
                folderPath: folderPath
            )

            guard !Task.isCancelled else { return }

            if let loaded {
                withAnimation(.easeIn(duration: 0.25)) {
                    midResImage = loaded
                }
            }
        }
    }
}

import SwiftUI
import ConjunctEngine

struct IndexingProgressCard: View {

    let progress: IndexingProgress
    let onDismiss: () -> Void

    @State private var autoDismissProgress: Double = 0.0
    @State private var autoDismissTask: Task<Void, Never>?
    private let autoDismissDelay: TimeInterval = 8.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // Phase header
            HStack {
                if progress.phase == .complete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else if progress.phase == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                } else {
                    ProgressView()
                        .scaleEffect(0.75)
                        .frame(width: 16, height: 16)
                }

                Text(progress.phase.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.appForeground)

                Spacer()
            }

            // Progress bar (in-progress phases only)
            if progress.phase != .complete && progress.phase != .failed {
                if progress.itemsTotal > 0 {
                    ProgressView(value: progress.fractionComplete)
                        .progressViewStyle(.linear)
                        .tint(Color.appMutedForeground)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Color.appMutedForeground)
                }
            }

            // Counters
            HStack(spacing: 16) {
                if progress.itemsTotal > 0 {
                    statLabel(
                        "\(progress.itemsComplete) / \(progress.itemsTotal)",
                        icon: "photo.stack"
                    )
                } else if progress.itemsComplete > 0 {
                    statLabel("\(progress.itemsComplete) found", icon: "doc.text.magnifyingglass")
                }

                if let eta = progress.eta, progress.phase == .extraction {
                    statLabel(formatETA(eta), icon: "clock")
                }

                if progress.phase == .complete {
                    statLabel("\(progress.itemsTotal) images", icon: "photo.stack")
                }
            }

            if let error = progress.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .lineLimit(2)
            } else if progress.phase != .complete {
                Text("Indexing continues in the background — feel free to browse.")
                    .font(.system(size: 11))
                    .foregroundColor(Color.appMutedForeground)
            }

            // Auto-dismiss button — fill animates left→right, triggers dismiss when full
            if progress.phase == .complete || progress.phase == .failed {
                dismissButton
            }
        }
        .padding(16)
        .frame(width: 288)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 4)
        .onDisappear { autoDismissTask?.cancel() }
    }

    private var dismissButton: some View {
        ZStack(alignment: .leading) {
            // Base track
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.appMutedForeground.opacity(0.12))

            // Fill layer
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.appMutedForeground.opacity(0.2))
                .scaleEffect(x: autoDismissProgress, y: 1, anchor: .leading)

            // Label
            Text("Got it")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color.appForeground)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 34)
        .onTapGesture { dismiss() }
        .onAppear { startAutoDismiss() }
    }

    private func startAutoDismiss() {
        autoDismissProgress = 0.0
        withAnimation(.linear(duration: autoDismissDelay)) {
            autoDismissProgress = 1.0
        }
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(autoDismissDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    private func dismiss() {
        autoDismissTask?.cancel()
        onDismiss()
    }

    private func statLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11))
            .foregroundColor(Color.appMutedForeground)
    }

    private func formatETA(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "< 1 min remaining" }
        let m = Int(seconds / 60)
        return "~\(m) min remaining"
    }
}

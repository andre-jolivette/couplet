import SwiftUI
import ConjunctEngine

/// Warning badge that appears in the bottom-right overlay when `health.issues` is non-empty.
/// Hidden entirely when everything is healthy. Opens a popover listing each issue with
/// a "Recheck Now" button that re-runs the inventory check.
/// Visual language matches the existing ThematicV2 progress pill (decision #105).
struct DependencyHealthView: View {

    let health: DependencyHealth
    let onRecheck: () async -> Void

    @State private var showPopover = false
    @State private var isRechecking = false

    var body: some View {
        if !health.isHealthy {
            badge
        }
    }

    private var badge: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
                Text(badgeLabel)
                    .font(.system(size: 11))
                    .foregroundColor(Color.appMutedForeground)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.appCard)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.orange.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            popoverContent
        }
        .transition(.opacity.animation(.easeInOut(duration: 0.3)))
    }

    private var badgeLabel: String {
        let n = health.issues.count
        return n == 1 ? "1 dependency issue" : "\(n) dependency issues"
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(health.issues) { issue in
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.appForeground)
                    Text(issue.body)
                        .font(.system(size: 11))
                        .foregroundColor(Color.appMutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()
                .background(Color.appBorder)

            Button {
                guard !isRechecking else { return }
                isRechecking = true
                Task {
                    await onRecheck()
                    isRechecking = false
                }
            } label: {
                HStack(spacing: 6) {
                    if isRechecking {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    }
                    Text(isRechecking ? "Checking…" : "Recheck Now")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .disabled(isRechecking)
            .foregroundColor(isRechecking ? Color.appMutedForeground : Color.appForeground)
        }
        .padding(14)
        .frame(width: 300)
        .background(Color.appCard)
    }
}

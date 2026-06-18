import SwiftUI
import AppKit
import ConjunctEngine

// MARK: - Root

/// Full-window setup flow shown only when Ollama or its required models are missing.
/// Dismissed by setting the parent's AppPhase to .ready — no dismiss action needed here.
struct SetupFlowView: View {
    let onComplete: () -> Void

    @StateObject private var manager = OllamaSetupManager()

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                SetupWindowChrome()
                Spacer()
                stepContent
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { manager.checkAndAdvance() }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch manager.step {
        case .checkingDependencies:
            CheckingView()
        case .installOllama:
            InstallOllamaView(onRecheck: { manager.checkAndAdvance() })
        case .pullingModels:
            PullingModelsView(manager: manager)
        case .done:
            DoneView(onComplete: onComplete)
        }
    }
}

// MARK: - Window chrome (title + step rail)

private struct SetupWindowChrome: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image("AppIcon")
                    .resizable().frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Text("Couplet").font(.system(size: 13, weight: .semibold)).foregroundColor(.appPrimary)
                Text("BETA")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.appMutedForeground)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.appMutedForeground.opacity(0.4), lineWidth: 0.5))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(Color.appBackground)
    }
}

// MARK: - Checking spinner

private struct CheckingView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView().controlSize(.regular).tint(.appMutedForeground)
            Text("Checking your setup…").font(.system(size: 14)).foregroundColor(.appMutedForeground)
        }
    }
}

// MARK: - Install Ollama step

private struct InstallOllamaView: View {
    let onRecheck: () -> Void
    @State private var rechecking = false

    var body: some View {
        VStack(spacing: 32) {
            stepRail(currentStep: 0)

            VStack(spacing: 6) {
                Text("Install Ollama")
                    .font(.system(size: 22, weight: .semibold)).foregroundColor(.appPrimary)
                Text("Couplet uses Ollama to run its AI models locally on your Mac.")
                    .font(.system(size: 14)).foregroundColor(.appMutedForeground)
                    .multilineTextAlignment(.center)
            }

            // Single row — Ollama itself
            SetupRow(
                title: "Ollama",
                badge: .needsYou,
                status: .notInstalled,
                detail: "This is the one part Couplet can't install for you. Download Ollama, then come back and check again. No need to pick any models yourself — Couplet sets those up in the next step."
            ) {
                HStack(spacing: 10) {
                    Button(action: openOllamaDownload) {
                        HStack(spacing: 5) {
                            Text("Download Ollama")
                            Image(systemName: "arrow.up.right").font(.system(size: 11))
                        }
                    }
                    .buttonStyle(SetupPrimaryButtonStyle())

                    Button(action: {
                        rechecking = true
                        onRecheck()
                    }) {
                        if rechecking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini).tint(.appMutedForeground)
                                Text("Checking…")
                            }
                        } else {
                            Text("I've installed it — check again")
                        }
                    }
                    .buttonStyle(SetupSecondaryButtonStyle())
                    .disabled(rechecking)
                }
            }
        }
        .frame(maxWidth: 540)
    }

    private func openOllamaDownload() {
        NSWorkspace.shared.open(URL(string: "https://ollama.com/download/mac")!)
    }
}

// MARK: - Pulling models step

private struct PullingModelsView: View {
    @ObservedObject var manager: OllamaSetupManager

    var body: some View {
        VStack(spacing: 32) {
            stepRail(currentStep: 1)

            VStack(spacing: 6) {
                Text("Getting your models ready")
                    .font(.system(size: 22, weight: .semibold)).foregroundColor(.appPrimary)
                Text("Couplet is downloading the two models it needs. This happens only once.")
                    .font(.system(size: 14)).foregroundColor(.appMutedForeground)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                captionRow
                thematicRow
            }
            .frame(maxWidth: 540)
        }
        .frame(maxWidth: 540)
        .onAppear { manager.startModelPull() }
        .onChange(of: manager.allModelsDone) { _, done in
            if done { manager.step = .done }
        }
    }

    private var captionRow: some View {
        ModelDownloadRow(
            name: "qwen2.5vl-caption",
            badge: .automatic,
            totalBytes: manager.captionTotalBytes,
            description: "Reads your photos and writes captions",
            phase: manager.captionModelPhase,
            onRetry: { manager.retryCaptionModel() }
        )
    }

    private var thematicRow: some View {
        ModelDownloadRow(
            name: "qwen2.5:14b-instruct",
            badge: .automatic,
            totalBytes: manager.thematicTotalBytes,
            description: "Finds the connections between photos",
            phase: manager.thematicModelPhase,
            onRetry: { manager.retryThematicModel() }
        )
    }
}

// MARK: - Done step

struct DoneView: View {
    let onComplete: () -> Void

    @State private var countdown: Int = 6
    @State private var sweepFraction: Double = 0
    @State private var isPaused = false
    @State private var isOpening = false
    @State private var timer: Timer? = nil

    var body: some View {
        VStack(spacing: 32) {
            stepRail(currentStep: 2)

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.setupSuccess.opacity(0.15))
                        .frame(width: 56, height: 56)
                    Image(systemName: "checkmark")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.setupSuccess)
                }

                VStack(spacing: 6) {
                    Text("You're all set")
                        .font(.system(size: 22, weight: .semibold)).foregroundColor(.appPrimary)
                    Text("Couplet is ready to go. Add a folder of photos\nwhenever you'd like to start finding pairs.")
                        .font(.system(size: 14)).foregroundColor(.appMutedForeground)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 6) {
                    checklistItem("Ollama installed")
                    checklistItem("Models ready")
                }
            }

            // Button is built inline so the sweep can cover the full button surface
            // (SetupPrimaryButtonStyle adds padding inside the label, which clips the GeometryReader).
            Button(action: advance) {
                ZStack(alignment: .leading) {
                    Color.setupAccent
                        .opacity(isOpening ? 0.9 : 1)
                    // Sweep — full-bleed, fills the entire button surface
                    GeometryReader { geo in
                        Color.white.opacity(0.15)
                            .frame(width: geo.size.width * sweepFraction,
                                   height: geo.size.height)
                    }
                    // Label centred over the sweep
                    HStack(spacing: 8) {
                        if isOpening || (countdown > 0 && !isPaused) {
                            ProgressView().controlSize(.mini).tint(.white)
                        }
                        Text(isOpening
                             ? "Opening Couplet\u{2026}"
                             : countdown > 0 && !isPaused
                                 ? "Opens automatically in \(countdown)s"
                                 : "Start using Couplet")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(width: 280, height: 40)  // fixed size prevents Color from expanding
            }
            .buttonStyle(.plain)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovering in isPaused = hovering }
            .disabled(isOpening)
        }
        .frame(maxWidth: 400)
        .onAppear { startCountdown() }
        .onDisappear { timer?.invalidate() }
    }

    private func advance() {
        guard !isOpening else { return }
        timer?.invalidate()
        isOpening = true
        sweepFraction = 1
        // Hold the "Opening Couplet…" state briefly before dismissing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { onComplete() }
    }

    private func checklistItem(_ label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").foregroundColor(.setupSuccess).font(.system(size: 11))
            Text(label).font(.system(size: 13)).foregroundColor(.appMutedForeground)
        }
    }

    private func startCountdown() {
        let totalSeconds: Double = 6
        var elapsed: Double = 0
        let interval: Double = 0.05
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { t in
            guard !isPaused, !isOpening else { return }
            elapsed += interval
            sweepFraction = min(elapsed / totalSeconds, 1.0)
            countdown = max(0, Int(ceil(totalSeconds - elapsed)))
            if elapsed >= totalSeconds {
                t.invalidate()
                advance()
            }
        }
    }
}

// MARK: - Shared components

private enum RowBadge { case needsYou, automatic }
private enum RowStatus { case notInstalled }

private struct SetupRow<Actions: View>: View {
    let title: String
    let badge: RowBadge
    let status: RowStatus?
    let detail: String
    @ViewBuilder let actions: () -> Actions

    init(title: String, badge: RowBadge, status: RowStatus? = nil, detail: String,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title; self.badge = badge; self.status = status
        self.detail = detail; self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ringGlyph
                Text(title)
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(.appPrimary)
                badgeView
                Spacer()
                if let status { statusLabel(status) }
            }
            Text(detail)
                .font(.system(size: 12)).foregroundColor(.appMutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            actions()
        }
        .padding(16)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(badgeColor.opacity(0.25), lineWidth: 1)
        )
    }

    private var badgeColor: Color {
        switch badge {
        case .needsYou:  return .setupAccent
        case .automatic: return .appMutedForeground
        }
    }

    private var ringGlyph: some View {
        Circle()
            .strokeBorder(badgeColor, lineWidth: 2)
            .frame(width: 20, height: 20)
    }

    private var badgeView: some View {
        Text(badge == .needsYou ? "NEEDS YOU" : "AUTOMATIC")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(badge == .needsYou ? .setupAccent : .appMutedForeground)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(badgeColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func statusLabel(_ s: RowStatus) -> some View {
        Text("Not installed")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(badgeColor)
    }
}

private struct ModelDownloadRow: View {
    let name: String
    let badge: RowBadge
    let totalBytes: Int64  // 0 = unknown (model already present or not yet started)
    let description: String
    let phase: ModelRowPhase
    let onRetry: (() -> Void)?

    private var sizeLabel: String? {
        totalBytes > 0 ? byteLabel(totalBytes) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                phaseIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.appPrimary)
                    Text(description)
                        .font(.system(size: 11)).foregroundColor(.appMutedForeground)
                }
                Spacer()
                // Show real size when known; hidden once model is already present
                if let sizeLabel, phase == .waiting {
                    Text(sizeLabel)
                        .font(.system(size: 12)).foregroundColor(.appMutedForeground)
                }
                phaseLabel
            }
            if case .downloading(let completed, let total) = phase, total > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(completed), total: Double(total))
                        .tint(.appPrimary)
                    HStack {
                        Text(byteLabel(completed) + " / " + byteLabel(total))
                            .font(.system(size: 11)).foregroundColor(.appMutedForeground)
                        Spacer()
                        Text(percentLabel(completed, total))
                            .font(.system(size: 11)).foregroundColor(.appMutedForeground)
                    }
                }
            } else if phase == .verifying {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(.appMutedForeground)
                    Text("Verifying…").font(.system(size: 11)).foregroundColor(.appMutedForeground)
                }
            } else if phase == .configuring {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(.appMutedForeground)
                    Text("Configuring…").font(.system(size: 11)).foregroundColor(.appMutedForeground)
                }
            } else if case .failed(let message) = phase {
                HStack(spacing: 10) {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let onRetry {
                        Button("Retry", action: onRetry)
                            .buttonStyle(SetupSecondaryButtonStyle())
                    }
                }
            }
        }
        .padding(16)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
    }

    private var phaseIcon: some View {
        Group {
            switch phase {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.setupSuccess).font(.system(size: 18))
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange).font(.system(size: 18))
            default:
                Circle()
                    .strokeBorder(Color.appMutedForeground.opacity(0.4), lineWidth: 1.5)
                    .frame(width: 18, height: 18)
            }
        }
    }

    @ViewBuilder
    private var phaseLabel: some View {
        switch phase {
        case .waiting:
            Text("Queued").font(.system(size: 12)).foregroundColor(.appMutedForeground)
        case .downloading:
            Text("Downloading").font(.system(size: 12, weight: .medium)).foregroundColor(.appPrimary)
        case .verifying:
            Text("Verifying").font(.system(size: 12, weight: .medium)).foregroundColor(.appPrimary)
        case .configuring:
            Text("Configuring").font(.system(size: 12, weight: .medium)).foregroundColor(.appPrimary)
        case .done:
            Text("Ready").font(.system(size: 12, weight: .medium)).foregroundColor(.setupSuccess)
        case .failed:
            Text("Failed").font(.system(size: 12, weight: .medium)).foregroundColor(.orange)
        }
    }

    private func byteLabel(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        return String(format: "%.1f GB", gb)
    }

    private func percentLabel(_ completed: Int64, _ total: Int64) -> String {
        let pct = Int((Double(completed) / Double(total)) * 100)
        return "\(pct)%"
    }
}

// MARK: - Step rail

private func stepRail(currentStep: Int) -> some View {
    HStack(spacing: 0) {
        ForEach(Array(zip(["Ollama", "Models", "Done"].indices, ["Ollama", "Models", "Done"])),
                id: \.0) { index, label in
            HStack(spacing: 0) {
                Circle()
                    .fill(index <= currentStep ? Color.setupSuccess : Color.appMutedForeground.opacity(0.3))
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.system(size: 12, weight: index == currentStep ? .semibold : .regular))
                    .foregroundColor(index == currentStep ? .appPrimary : .appMutedForeground)
                    .padding(.leading, 6)
                if index < 2 {
                    Rectangle()
                        .fill(Color.appMutedForeground.opacity(0.2))
                        .frame(height: 1)
                        .frame(maxWidth: 80)
                        .padding(.horizontal, 12)
                }
            }
        }
    }
}

// MARK: - Button styles

struct SetupPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.setupAccent.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SetupSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundColor(.appMutedForeground)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.appSecondary.opacity(configuration.isPressed ? 0.6 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

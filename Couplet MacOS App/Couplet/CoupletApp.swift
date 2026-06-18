import SwiftUI
import ConjunctEngine

// MARK: - App phase

private enum AppPhase {
    /// Initial check before any window shows content.
    case checking
    /// Ollama or a required model is missing — show the setup flow.
    case settingUp
    /// Dependencies satisfied — show the main window.
    case ready
}

@main
struct CoupletApp: App {

    @State private var settingsStore: SettingsStore
    @StateObject private var engine: EngineController
    @State private var phase: AppPhase = .checking

    init() {
        let store = SettingsStore()
        _settingsStore = State(initialValue: store)
        _engine = StateObject(wrappedValue: EngineController(settings: store))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch phase {
                case .checking:
                    // Transparent placeholder — check is fast (single HTTP probe)
                    Color.appBackground.ignoresSafeArea()
                case .settingUp:
                    SetupFlowView {
                        // Re-verify before proceeding so the doctor pill stays dark
                        Task {
                            await engine.checkDependencyHealth()
                            phase = .ready
                        }
                    }
                case .ready:
                    ContentView()
                        .environmentObject(engine)
                        .environment(settingsStore)
                }
            }
            .preferredColorScheme(.dark)
            .task {
                guard phase == .checking else { return }
                let inventory = await OllamaInventory.check()
                let needsSetup = !inventory.reachable
                    || !inventory.has(model: "qwen2.5vl-caption")
                    || !inventory.has(model: "qwen2.5:14b-instruct")
                phase = needsSetup ? .settingUp : .ready
                // Initialize the engine regardless so it's ready when setup completes
                engine.initialize()
            }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Pairs") {
                Button("Add Folder\u{2026}") {}
                    .keyboardShortcut("o", modifiers: [.command])
                Divider()
                Button("Favorite") {}
                    .keyboardShortcut("l", modifiers: [])
                Button("Reject") {}
                    .keyboardShortcut("x", modifiers: [])
            }
        }

        Settings {
            SettingsView(store: settingsStore, engine: engine)
        }
    }
}

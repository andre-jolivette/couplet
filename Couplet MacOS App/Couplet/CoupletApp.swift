import SwiftUI

@main
struct CoupletApp: App {

    @State private var settingsStore: SettingsStore
    @StateObject private var engine: EngineController

    init() {
        let store = SettingsStore()
        _settingsStore = State(initialValue: store)
        _engine = StateObject(wrappedValue: EngineController(settings: store))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .environment(settingsStore)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
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
            SettingsView(store: settingsStore)
        }
    }
}

import SwiftUI

@main
struct WisperApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 920, minHeight: 620)
        }
        .windowStyle(.titleBar)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 520)
        }
    }
}

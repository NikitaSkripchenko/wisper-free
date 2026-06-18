import SwiftUI

@main
struct WisperApp: App {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var appState: AppState
    @StateObject private var updateController: UpdateController

    init() {
        let appState = AppState()
        _appState = StateObject(wrappedValue: appState)
        _updateController = StateObject(wrappedValue: UpdateController(
            activityPublisher: appState.$activity.eraseToAnyPublisher(),
            initialActivity: appState.activity,
            setAppInstallPending: { [weak appState] isPending in
                appState?.setUpdateInstallPending(isPending)
            }
        ))
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 920, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updateController: updateController)
            }
        }

        MenuBarExtra(isInserted: Binding(
            get: { appState.showInMenuBarOnly },
            set: { _ in }
        )) {
            Button("Show Wisper") {
                showMainWindow()
            }

            Divider()

            Button(recordingMenuTitle) {
                Task {
                    if appState.recorder.phase == .recording || appState.recorder.phase == .paused {
                        await appState.stopRecording()
                    } else {
                        await appState.startRecording()
                    }
                }
            }
            .disabled(appState.isProcessing)

            Button(appState.recorder.isPaused ? "Resume Recording" : "Pause Recording") {
                appState.recorder.isPaused ? appState.resumeRecording() : appState.pauseRecording()
            }
            .disabled(appState.recorder.canPause == false || appState.isProcessing)

            Divider()

            Button("Settings") {
                appState.selectedSection = .settings
                showMainWindow()
            }

            Button("Refresh Audio Sources") {
                appState.refreshAudioSources()
            }
            .disabled(appState.recorder.isRecording || appState.isProcessing)

            Divider()

            CheckForUpdatesButton(updateController: updateController)

            Divider()

            Button("Quit Wisper") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Label("Wisper", systemImage: menuIconName)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 520)
        }
    }

    private var recordingMenuTitle: String {
        if appState.recorder.phase == .recording || appState.recorder.phase == .paused {
            return "Stop and Transcribe"
        }

        return "Start Recording"
    }

    private var menuIconName: String {
        if appState.isProcessing { return "waveform.badge.magnifyingglass" }
        if appState.recorder.isPaused { return "pause.circle.fill" }
        if appState.recorder.isRecording { return "waveform.circle.fill" }
        return "mic.circle"
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

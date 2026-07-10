import SwiftUI

@main
struct WisperApp: App {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var appViewModel: AppViewModel
    @StateObject private var updateController: UpdateController

    init() {
        let appViewModel = AppViewModel()
        _appViewModel = StateObject(wrappedValue: appViewModel)
        _updateController = StateObject(wrappedValue: UpdateController(
            activityPublisher: appViewModel.$activity.eraseToAnyPublisher(),
            initialActivity: appViewModel.activity,
            setAppInstallPending: { [weak appViewModel] isPending in
                appViewModel?.setUpdateInstallPending(isPending)
            }
        ))
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(appViewModel)
                .frame(minWidth: 920, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updateController: updateController)
            }
        }

        MenuBarExtra(isInserted: Binding(
            get: { appViewModel.showInMenuBarOnly },
            set: { _ in }
        )) {
            Button("Show Wisper") {
                showMainWindow()
            }

            Divider()

            Button(recordingMenuTitle) {
                Task {
                    if appViewModel.recorder.phase == .recording || appViewModel.recorder.phase == .paused {
                        await appViewModel.stopRecording()
                    } else {
                        await appViewModel.startRecording()
                    }
                }
            }
            .disabled(appViewModel.isProcessing)

            Button(appViewModel.recorder.isPaused ? "Resume Recording" : "Pause Recording") {
                appViewModel.recorder.isPaused ? appViewModel.resumeRecording() : appViewModel.pauseRecording()
            }
            .disabled(appViewModel.recorder.canPause == false || appViewModel.isProcessing)

            Divider()

            Button("Settings") {
                appViewModel.selectedSection = .settings
                showMainWindow()
            }

            Button("Refresh Audio Sources") {
                appViewModel.refreshAudioSources()
            }
            .disabled(appViewModel.recorder.isRecording || appViewModel.isProcessing)

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
                .environmentObject(appViewModel)
                .frame(width: 520)
        }
    }

    private var recordingMenuTitle: String {
        if appViewModel.recorder.phase == .recording || appViewModel.recorder.phase == .paused {
            return "Stop and Transcribe"
        }

        return "Start Recording"
    }

    private var menuIconName: String {
        if appViewModel.isProcessing { return "waveform.badge.magnifyingglass" }
        if appViewModel.recorder.isPaused { return "pause.circle.fill" }
        if appViewModel.recorder.isRecording { return "waveform.circle.fill" }
        return "mic.circle"
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

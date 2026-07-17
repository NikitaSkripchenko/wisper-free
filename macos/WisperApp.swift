import Combine
import SwiftUI

@main
struct WisperApp: App {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var appViewModel: AppViewModel
    @StateObject private var updateController: UpdateController

    init() {
        let appViewModel = AppViewModel()
        let coordinator = appViewModel.meetingCoordinator
        let safetyPublisher = Publishers.CombineLatest4(
            coordinator.$bootstrapState,
            coordinator.$activeMeetingID,
            coordinator.$isCapturing,
            coordinator.$isProcessing
        )
        .map { bootstrapState, activeMeetingID, isCapturing, isProcessing in
            bootstrapState == .ready && activeMeetingID == nil && isCapturing == false && isProcessing == false
        }
        .eraseToAnyPublisher()
        _appViewModel = StateObject(wrappedValue: appViewModel)
        _updateController = StateObject(wrappedValue: UpdateController(
            safetyPublisher: safetyPublisher,
            initiallySafeToTerminate: coordinator.canSafelyTerminate,
            setAppInstallPending: { [weak appViewModel] isPending in
                appViewModel?.setUpdateInstallPending(isPending)
            }
        ))
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(appViewModel)
                .environmentObject(appViewModel.meetingCoordinator)
                .frame(minWidth: 920, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}

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

            if appViewModel.recorder.isRecording {
                Text("Recording · \(appViewModel.recorder.elapsedDisplay)")
            }

            Button(appViewModel.recorder.isPaused ? "Resume Recording" : "Pause Recording") {
                appViewModel.recorder.isPaused ? appViewModel.resumeRecording() : appViewModel.pauseRecording()
            }
            .disabled(appViewModel.recorder.canPause == false || appViewModel.isProcessing)

            if let record = activeMenuRecord {
                Divider()
                Text(record.title)
                Text(record.displayState.statusText)
                Button("Open Active Meeting") {
                    appViewModel.openMeeting(id: record.id)
                    showMainWindow()
                }
                .accessibilityLabel("Open active meeting, \(record.title), \(record.displayState.statusText)")
            } else if let record = recentMenuRecord {
                Divider()
                Button("Open Meeting") {
                    appViewModel.openMeeting(id: record.id)
                    showMainWindow()
                }
                .accessibilityLabel("Open meeting, \(record.title), \(record.displayState.statusText)")
            }

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
                .environmentObject(appViewModel.meetingCoordinator)
                .frame(width: 520)
        }
    }

    private var recordingMenuTitle: String {
        if appViewModel.recorder.phase == .recording || appViewModel.recorder.phase == .paused {
            return "Stop and Transcribe"
        }

        return "Start Recording"
    }

    private var activeMenuRecord: MeetingRecord? {
        guard let id = appViewModel.meetingCoordinator.activeMeetingID else { return nil }
        return appViewModel.meetingCoordinator.records.first(where: { $0.id == id })
    }

    private var recentMenuRecord: MeetingRecord? {
        guard appViewModel.recorder.isRecording == false,
              appViewModel.isProcessing == false else { return nil }
        return appViewModel.meetingCoordinator.records.first
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

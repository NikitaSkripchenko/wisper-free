import Combine
import SwiftUI

@main
struct WisperApp: App {
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

        Settings {
            SettingsView()
                .environmentObject(appViewModel)
                .environmentObject(appViewModel.meetingCoordinator)
                .frame(width: 520)
        }
    }

}

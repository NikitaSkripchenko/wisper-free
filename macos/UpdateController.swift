import Combine
import Sparkle
import SwiftUI

@MainActor
final class UpdateRelaunchGate {
    private var pendingInstallHandler: (() -> Void)?

    var hasPendingInstall: Bool {
        pendingInstallHandler != nil
    }

    func shouldPostpone(activity: AppActivity, installHandler: @escaping () -> Void) -> Bool {
        guard activity.blocksUpdateInstallation else { return false }

        if pendingInstallHandler == nil {
            pendingInstallHandler = installHandler
        }
        return true
    }

    @discardableResult
    func activityDidChange(_ activity: AppActivity) -> Bool {
        guard activity.blocksUpdateInstallation == false, let installHandler = pendingInstallHandler else {
            return false
        }

        pendingInstallHandler = nil
        installHandler()
        return true
    }

    func cancelPendingInstall() {
        pendingInstallHandler = nil
    }
}

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isInstallPending = false

    private let relaunchGate = UpdateRelaunchGate()
    private let setAppInstallPending: (Bool) -> Void
    private var currentActivity: AppActivity
    private var updaterController: SPUStandardUpdaterController!
    private var cancellables: Set<AnyCancellable> = []

    init(
        activityPublisher: AnyPublisher<AppActivity, Never>,
        initialActivity: AppActivity,
        setAppInstallPending: @escaping (Bool) -> Void,
        startUpdater: Bool = true
    ) {
        self.currentActivity = initialActivity
        self.setAppInstallPending = setAppInstallPending
        super.init()

        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheckForUpdates in
                self?.canCheckForUpdates = canCheckForUpdates
            }
            .store(in: &cancellables)

        activityPublisher
            .sink { [weak self] activity in
                guard let self else { return }
                currentActivity = activity
                _ = relaunchGate.activityDidChange(activity)
            }
            .store(in: &cancellables)

        if startUpdater {
            updaterController.startUpdater()
        }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        let shouldPostpone = relaunchGate.shouldPostpone(
            activity: currentActivity,
            installHandler: installHandler
        )

        if shouldPostpone {
            isInstallPending = true
            setAppInstallPending(true)
        }
        return shouldPostpone
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        relaunchGate.cancelPendingInstall()
        isInstallPending = false
        setAppInstallPending(false)
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updateController: UpdateController

    var body: some View {
        Button("Check for Updates…") {
            updateController.checkForUpdates()
        }
        .disabled(updateController.canCheckForUpdates == false)
    }
}

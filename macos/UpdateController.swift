import Combine
import Sparkle
import SwiftUI

@MainActor
final class UpdateRelaunchGate {
    private var pendingInstallHandler: (() -> Void)?

    var hasPendingInstall: Bool {
        pendingInstallHandler != nil
    }

    func shouldPostpone(canSafelyTerminate: Bool, installHandler: @escaping () -> Void) -> Bool {
        guard canSafelyTerminate == false else { return false }

        if pendingInstallHandler == nil {
            pendingInstallHandler = installHandler
        }
        return true
    }

    @discardableResult
    func safetyDidChange(canSafelyTerminate: Bool) -> Bool {
        guard canSafelyTerminate, let installHandler = pendingInstallHandler else {
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
    private var canSafelyTerminate: Bool
    private var updaterController: SPUStandardUpdaterController!
    private var cancellables: Set<AnyCancellable> = []

    init(
        safetyPublisher: AnyPublisher<Bool, Never>,
        initiallySafeToTerminate: Bool,
        setAppInstallPending: @escaping (Bool) -> Void,
        startUpdater: Bool = true
    ) {
        canSafelyTerminate = initiallySafeToTerminate
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

        safetyPublisher
            .removeDuplicates()
            .sink { [weak self] isSafe in
                guard let self else { return }
                canSafelyTerminate = isSafe
                if relaunchGate.safetyDidChange(canSafelyTerminate: isSafe) {
                    isInstallPending = false
                    setAppInstallPending(false)
                }
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
            canSafelyTerminate: canSafelyTerminate,
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

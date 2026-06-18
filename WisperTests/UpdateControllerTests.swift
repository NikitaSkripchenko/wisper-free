import XCTest
@testable import Wisper

@MainActor
final class UpdateControllerTests: XCTestCase {
    func testIdleActivityDoesNotPostponeRelaunch() {
        let gate = UpdateRelaunchGate()
        var installCount = 0

        let postponed = gate.shouldPostpone(activity: .idle) {
            installCount += 1
        }

        XCTAssertFalse(postponed)
        XCTAssertFalse(gate.hasPendingInstall)
        XCTAssertEqual(installCount, 0)
    }

    func testBusyActivityDefersUntilIdleExactlyOnce() {
        let gate = UpdateRelaunchGate()
        var installCount = 0

        XCTAssertTrue(gate.shouldPostpone(activity: .recording) {
            installCount += 1
        })
        XCTAssertTrue(gate.hasPendingInstall)

        XCTAssertFalse(gate.activityDidChange(.stoppingRecording))
        XCTAssertFalse(gate.activityDidChange(.transcribing))
        XCTAssertTrue(gate.activityDidChange(.idle))
        XCTAssertFalse(gate.activityDidChange(.idle))

        XCTAssertFalse(gate.hasPendingInstall)
        XCTAssertEqual(installCount, 1)
    }

    func testRestartTransitionNeverLeaksIdle() {
        let gate = UpdateRelaunchGate()
        var installCount = 0

        XCTAssertTrue(gate.shouldPostpone(activity: .recording) {
            installCount += 1
        })

        XCTAssertFalse(gate.activityDidChange(.restartingRecording))
        XCTAssertFalse(gate.activityDidChange(.recording))
        XCTAssertEqual(installCount, 0)
    }

    func testRepeatedPostponeRequestKeepsOriginalHandler() {
        let gate = UpdateRelaunchGate()
        var firstInstallCount = 0
        var secondInstallCount = 0

        XCTAssertTrue(gate.shouldPostpone(activity: .recording) {
            firstInstallCount += 1
        })
        XCTAssertTrue(gate.shouldPostpone(activity: .transcribing) {
            secondInstallCount += 1
        })

        XCTAssertTrue(gate.activityDidChange(.idle))
        XCTAssertEqual(firstInstallCount, 1)
        XCTAssertEqual(secondInstallCount, 0)
    }

    func testAbortClearsPendingHandler() {
        let gate = UpdateRelaunchGate()
        var installCount = 0

        XCTAssertTrue(gate.shouldPostpone(activity: .discardingRecording) {
            installCount += 1
        })
        gate.cancelPendingInstall()

        XCTAssertFalse(gate.activityDidChange(.idle))
        XCTAssertFalse(gate.hasPendingInstall)
        XCTAssertEqual(installCount, 0)
    }
}

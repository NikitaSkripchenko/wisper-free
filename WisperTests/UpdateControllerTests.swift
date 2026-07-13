import XCTest
@testable import Wisper

@MainActor
final class UpdateControllerTests: XCTestCase {
    func testSafeCoordinatorDoesNotPostponeRelaunch() {
        let gate = UpdateRelaunchGate()
        var installCount = 0

        let postponed = gate.shouldPostpone(canSafelyTerminate: true) {
            installCount += 1
        }

        XCTAssertFalse(postponed)
        XCTAssertFalse(gate.hasPendingInstall)
        XCTAssertEqual(installCount, 0)
    }

    func testUnsafeCoordinatorDefersUntilSafeExactlyOnce() {
        let gate = UpdateRelaunchGate()
        var installCount = 0

        XCTAssertTrue(gate.shouldPostpone(canSafelyTerminate: false) {
            installCount += 1
        })
        XCTAssertTrue(gate.hasPendingInstall)

        XCTAssertFalse(gate.safetyDidChange(canSafelyTerminate: false))
        XCTAssertTrue(gate.safetyDidChange(canSafelyTerminate: true))
        XCTAssertFalse(gate.safetyDidChange(canSafelyTerminate: true))

        XCTAssertFalse(gate.hasPendingInstall)
        XCTAssertEqual(installCount, 1)
    }

    func testUnsafeTransitionsNeverReleasePendingInstall() {
        let gate = UpdateRelaunchGate()
        var installCount = 0

        XCTAssertTrue(gate.shouldPostpone(canSafelyTerminate: false) {
            installCount += 1
        })

        XCTAssertFalse(gate.safetyDidChange(canSafelyTerminate: false))
        XCTAssertFalse(gate.safetyDidChange(canSafelyTerminate: false))
        XCTAssertEqual(installCount, 0)
    }

    func testRepeatedPostponeRequestKeepsOriginalHandler() {
        let gate = UpdateRelaunchGate()
        var firstInstallCount = 0
        var secondInstallCount = 0

        XCTAssertTrue(gate.shouldPostpone(canSafelyTerminate: false) {
            firstInstallCount += 1
        })
        XCTAssertTrue(gate.shouldPostpone(canSafelyTerminate: false) {
            secondInstallCount += 1
        })

        XCTAssertTrue(gate.safetyDidChange(canSafelyTerminate: true))
        XCTAssertEqual(firstInstallCount, 1)
        XCTAssertEqual(secondInstallCount, 0)
    }

    func testAbortClearsPendingHandler() {
        let gate = UpdateRelaunchGate()
        var installCount = 0

        XCTAssertTrue(gate.shouldPostpone(canSafelyTerminate: false) {
            installCount += 1
        })
        gate.cancelPendingInstall()

        XCTAssertFalse(gate.safetyDidChange(canSafelyTerminate: true))
        XCTAssertFalse(gate.hasPendingInstall)
        XCTAssertEqual(installCount, 0)
    }
}

import XCTest

@MainActor
final class WisperMeetingFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    func testBootstrapGatesRecordingUntilStoreIsReady() {
        launch(fixture: "empty", bootstrapDelayMilliseconds: 10_000)
        let record = element(identifier: "sidebar.record")

        XCTAssertTrue(record.waitForExistence(timeout: 3))
        XCTAssertFalse(record.isEnabled)
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: record)
        waitForExpectations(timeout: 12)
    }

    func testCompletedMeetingShowsGroundedNotesTranscriptAndActions() {
        launch(fixture: "complete")
        openMeeting()

        XCTAssertTrue(element(identifier: "meeting.notes").waitForExistence(timeout: 3))
        XCTAssertGreaterThan(elementCount(identifier: "notes.item"), 0)
        selectTab("Raw transcript")
        XCTAssertTrue(element(identifier: "meeting.transcript").exists)

        element(identifier: "meeting.more").click()
        XCTAssertTrue(app.menuItems["Regenerate Transcript"].exists)
        XCTAssertTrue(app.menuItems["Regenerate Notes"].exists)
        XCTAssertTrue(app.menuItems["Copy Notes"].exists)
        XCTAssertTrue(app.menuItems["Copy Raw Transcript"].exists)
        XCTAssertTrue(app.menuItems["Remove Meeting"].exists)
    }

    func testEmptyCategoriesRenderExplicitly() {
        launch(fixture: "empty-categories")
        openMeeting()

        XCTAssertTrue(element(identifier: "meeting.notes").waitForExistence(timeout: 3))
        let emptyLabels = elementCount(identifier: "notes.empty")
        XCTAssertGreaterThanOrEqual(emptyLabels, 3)
    }

    func testNotesFailureKeepsTranscriptAndOffersRetryAndRemovalConfirmation() {
        launch(fixture: "notes-failed")
        openMeeting()

        XCTAssertTrue(app.buttons["Retry notes"].waitForExistence(timeout: 3))
        selectTab("Raw transcript")
        XCTAssertTrue(element(identifier: "meeting.transcript").exists)
        element(identifier: "meeting.more").click()
        app.menuItems["Remove Meeting"].click()
        XCTAssertTrue(app.staticTexts[
            "Remove this meeting and all of its owned audio, transcript, and notes?"
        ].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Cancel"].exists)
    }

    func testOnboardingExplainsLocalAndOpenAIPrivacyBoundary() {
        launch(fixture: "empty", showOnboarding: true)

        XCTAssertTrue(element(identifier: "onboarding.privacy").waitForExistence(timeout: 3))
        XCTAssertTrue(element(identifier: "onboarding.finish").exists)
    }

    func testEmptyWorkspaceOffersRecordAndImport() {
        launch(fixture: "empty")

        XCTAssertTrue(element(identifier: "sidebar.record").waitForExistence(timeout: 3))
        XCTAssertTrue(element(identifier: "sidebar.import").exists)
        XCTAssertFalse(element(identifier: "meeting.row").exists)
    }

    func testSearchShowsZeroStateAndClearRestoresMeeting() {
        launch(fixture: "complete")

        XCTAssertTrue(element(identifier: "meeting.row").waitForExistence(timeout: 3))
        let search = element(identifier: "sidebar.search")
        XCTAssertTrue(search.exists)
        search.click()
        search.typeText("quarterly review")
        XCTAssertTrue(app.buttons["Clear Search"].waitForExistence(timeout: 2))
        XCTAssertFalse(element(identifier: "meeting.row").exists)

        app.buttons["Clear Search"].click()
        XCTAssertTrue(element(identifier: "meeting.row").waitForExistence(timeout: 2))
    }

    func testRenamePreservesSelectedTabAndCommitsFromKeyboard() {
        launch(fixture: "complete")
        openMeeting()
        selectTab("Audio")
        XCTAssertTrue(element(identifier: "meeting.audio").waitForExistence(timeout: 2))

        element(identifier: "meeting.title").click()
        let field = element(identifier: "meeting.rename.field")
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Renamed café")
        field.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(element(labelContaining: "Renamed café").waitForExistence(timeout: 2))
        XCTAssertTrue(element(identifier: "meeting.audio").exists)
    }

    func testMinimumWindowKeepsCoreMeetingControlsVisible() {
        launch(fixture: "complete")
        openMeeting()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(window.frame.width, 920)
        XCTAssertGreaterThanOrEqual(window.frame.height, 620)
        XCTAssertTrue(element(identifier: "meeting.tabs").waitForExistence(timeout: 2))
        XCTAssertTrue(element(identifier: "meeting.more").exists)
    }

    private func launch(
        fixture: String,
        bootstrapDelayMilliseconds: Int? = nil,
        showOnboarding: Bool = false
    ) {
        app = XCUIApplication()
        app.launchEnvironment["WISPER_UI_TEST_ROOT"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("WisperUITests-\(UUID().uuidString)", isDirectory: true)
            .path
        app.launchEnvironment["WISPER_UI_TEST_FIXTURE"] = fixture
        if let bootstrapDelayMilliseconds {
            app.launchEnvironment["WISPER_UI_TEST_BOOTSTRAP_DELAY_MS"] = String(bootstrapDelayMilliseconds)
        }
        if showOnboarding {
            app.launchEnvironment["WISPER_UI_TEST_ONBOARDING"] = "1"
        }
        app.launch()
    }

    private func openMeeting() {
        let row = element(identifier: "meeting.row")
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.click()
    }

    private func element(labelContaining text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func element(identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func elementCount(identifier: String) -> Int {
        app.descendants(matching: .any).matching(identifier: identifier).count
    }

    private func selectTab(_ title: String) {
        let tab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title))
            .firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 2))
        tab.click()
    }
}

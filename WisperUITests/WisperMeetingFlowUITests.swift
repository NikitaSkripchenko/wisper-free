import XCTest

@MainActor
final class WisperMeetingFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    func testBootstrapGatesHistoryUntilStoreIsReady() {
        launch(fixture: "empty", bootstrapDelayMilliseconds: 10_000)
        let startRecording = app.buttons["Start Recording"]

        XCTAssertTrue(startRecording.waitForExistence(timeout: 3))
        XCTAssertFalse(startRecording.isEnabled)
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: startRecording)
        waitForExpectations(timeout: 12)
    }

    func testCompletedMeetingShowsGroundedNotesTranscriptAndActions() {
        launch(fixture: "complete")
        openHistory()

        XCTAssertTrue(app.staticTexts["UI Test Planning Call"].waitForExistence(timeout: 3))
        XCTAssertTrue(element(identifier: "meeting.notes").exists)
        XCTAssertGreaterThan(elementCount(identifier: "notes.item"), 0)
        selectTab("Raw Transcript")
        XCTAssertTrue(element(identifier: "meeting.transcript").exists)

        element(identifier: "meeting.more").click()
        XCTAssertTrue(app.menuItems["Copy Notes"].exists)
        XCTAssertTrue(app.menuItems["Copy Raw Transcript"].exists)
        XCTAssertTrue(app.menuItems["Remove Meeting"].exists)
    }

    func testEmptyCategoriesRenderExplicitly() {
        launch(fixture: "empty-categories")
        openHistory()

        XCTAssertTrue(app.staticTexts["UI Test Planning Call"].waitForExistence(timeout: 3))
        let emptyLabels = elementCount(identifier: "notes.empty")
        XCTAssertGreaterThanOrEqual(emptyLabels, 3)
    }

    func testNotesFailureKeepsTranscriptAndOffersRetryAndRemovalConfirmation() {
        launch(fixture: "notes-failed")
        openHistory()

        XCTAssertTrue(app.buttons["Retry Notes"].waitForExistence(timeout: 3))
        selectTab("Raw Transcript")
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

        XCTAssertTrue(app.staticTexts["Stays on your Mac"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Sent to OpenAI when processing"].exists)
        XCTAssertTrue(app.staticTexts["Wisper adds no meeting bot. Record only with everyone’s consent; recording laws vary by location."].exists)
    }

    func testRecordIsCaptureOnlyAndEmptyHistoryOffersBothCreationPaths() {
        launch(fixture: "empty")

        XCTAssertTrue(app.buttons["Start Recording"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Latest Transcript"].exists)
        openHistory()
        XCTAssertTrue(element(identifier: "history.record").waitForExistence(timeout: 3))
        XCTAssertTrue(element(identifier: "history.import").exists)

        element(identifier: "history.record").click()
        XCTAssertTrue(app.buttons["Start Recording"].waitForExistence(timeout: 2))
    }

    func testHistorySearchShowsZeroStateAndClearRestoresMeeting() {
        launch(fixture: "complete")
        openHistory()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        app.typeKey("f", modifierFlags: .command)
        search.click()
        search.typeText("quarterly review")
        XCTAssertTrue(app.buttons["Clear Search"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["UI Test Planning Call"].exists)

        app.buttons["Clear Search"].click()
        XCTAssertTrue(app.staticTexts["UI Test Planning Call"].waitForExistence(timeout: 2))
    }

    func testRenamePreservesSelectedTabAndCommitsFromKeyboard() {
        launch(fixture: "complete")
        openHistory()
        XCTAssertTrue(app.staticTexts["UI Test Planning Call"].waitForExistence(timeout: 3))
        selectTab("Audio")
        XCTAssertTrue(element(identifier: "meeting.audio").exists)

        element(identifier: "meeting.title").click()
        let field = element(identifier: "meeting.rename.field")
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Renamed café")
        field.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(app.staticTexts["Renamed café"].waitForExistence(timeout: 2))
        XCTAssertTrue(element(identifier: "meeting.audio").exists)
    }

    func testMinimumWindowKeepsCoreHistoryControlsVisible() {
        launch(fixture: "complete")
        openHistory()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(window.frame.width, 920)
        XCTAssertGreaterThanOrEqual(window.frame.height, 620)
        XCTAssertTrue(element(identifier: "meeting.tabs").exists)
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

    private func openHistory() {
        let history = app.staticTexts["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 3))
        history.click()
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

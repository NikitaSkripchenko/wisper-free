import XCTest
@testable import Wisper

final class AppPersistenceStoresTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "WisperTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testSettingsStoreLoadsDefaultWhenFileIsMissing() throws {
        let store = JSONAppSettingsStore(settingsURL: temporaryDirectory.appending(path: "missing-settings.json"))

        let settings = try store.load()

        XCTAssertEqual(settings.shortcut, .default)
        XCTAssertTrue(settings.chunkingEnabled)
        XCTAssertFalse(settings.onboardingCompleted)
    }

    func testSettingsStoreMigratesLegacyShortcutFile() throws {
        let settingsURL = temporaryDirectory.appending(path: "settings.json")
        let legacyShortcut = KeyboardShortcut(keyCode: 9, carbonModifiers: 256, displayText: "Command V")
        let data = try JSONEncoder.wisper.encode(legacyShortcut)
        try data.write(to: settingsURL, options: .atomic)
        let store = JSONAppSettingsStore(settingsURL: settingsURL)

        let settings = try store.load()

        XCTAssertEqual(settings.shortcut, legacyShortcut)
        XCTAssertTrue(settings.chunkingEnabled)
        XCTAssertFalse(settings.onboardingCompleted)
    }

    func testSettingsStoreSavesAndLoadsSettings() throws {
        let settingsURL = temporaryDirectory.appending(path: "settings/settings.json")
        let store = JSONAppSettingsStore(settingsURL: settingsURL)
        let expected = AppSettings(
            shortcut: KeyboardShortcut(keyCode: 12, carbonModifiers: 512, displayText: "Option Q"),
            chunkingEnabled: false,
            chunkSeconds: 120,
            audioSourceID: "external-mic",
            captureMode: .systemAudio,
            showInMenuBarOnly: true,
            onboardingCompleted: true
        )

        try store.save(expected)
        let loaded = try store.load()

        XCTAssertEqual(loaded.shortcut, expected.shortcut)
        XCTAssertEqual(loaded.chunkingEnabled, expected.chunkingEnabled)
        XCTAssertEqual(loaded.chunkSeconds, expected.chunkSeconds)
        XCTAssertEqual(loaded.audioSourceID, expected.audioSourceID)
        XCTAssertEqual(loaded.captureMode, expected.captureMode)
        XCTAssertEqual(loaded.showInMenuBarOnly, expected.showInMenuBarOnly)
        XCTAssertEqual(loaded.onboardingCompleted, expected.onboardingCompleted)
    }

    func testHistoryStoreSavesAndLoadsTranscripts() throws {
        let historyURL = temporaryDirectory.appending(path: "history/history.json")
        let store = JSONTranscriptHistoryStore(historyURL: historyURL)
        let expected = [
            Transcript(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                createdAt: Date(timeIntervalSince1970: 100),
                originalName: "meeting.m4a",
                audioPath: "/tmp/meeting.m4a",
                durationSeconds: 42,
                status: .completed,
                transcriptionText: "Transcript text",
                mode: "plain",
                updatedAt: Date(timeIntervalSince1970: 200)
            )
        ]

        try store.save(expected)
        let loaded = try store.load()

        XCTAssertEqual(loaded, expected)
    }

    func testSettingsStoreThrowsWhenSettingsFileIsCorrupt() throws {
        let settingsURL = temporaryDirectory.appending(path: "settings.json")
        try Data("not-json".utf8).write(to: settingsURL, options: .atomic)
        let store = JSONAppSettingsStore(settingsURL: settingsURL)

        XCTAssertThrowsError(try store.load())
    }

    func testHistoryStoreThrowsWhenHistoryFileIsCorrupt() throws {
        let historyURL = temporaryDirectory.appending(path: "history.json")
        try Data("not-json".utf8).write(to: historyURL, options: .atomic)
        let store = JSONTranscriptHistoryStore(historyURL: historyURL)

        XCTAssertThrowsError(try store.load())
    }
}

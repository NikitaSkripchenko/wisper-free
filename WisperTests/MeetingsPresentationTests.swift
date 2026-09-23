import Foundation
import XCTest
@testable import Wisper

final class MeetingsPresentationTests: XCTestCase {
    func testSearchMatchesTitleAndDateButNotTranscriptText() throws {
        let presenter = MeetingHistoryMetadataPresenter(
            locale: Locale(identifier: "en_US_POSIX"),
            calendar: {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                return calendar
            }(),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        var record = try makeRecord()
        record.title = "Pricing sync"

        XCTAssertTrue(presenter.matches(record, query: "Pricing"))
        XCTAssertTrue(presenter.matches(record, query: presenter.dateText(for: record)))
        // The transcript itself is never part of a MeetingRecord's metadata, so a
        // phrase that only ever appears in transcript text cannot match here.
        XCTAssertFalse(presenter.matches(record, query: "usage-based tier"))
    }

    func testRowChipReflectsDisplayState() {
        XCTAssertEqual(MeetingRowChip(state: .captured), .none)
        XCTAssertEqual(MeetingRowChip(state: .transcriptReady), .none)
        XCTAssertEqual(MeetingRowChip(state: .complete), .none)
        XCTAssertEqual(MeetingRowChip(state: .transcribing), .transcribing)
        XCTAssertEqual(MeetingRowChip(state: .generatingNotes), .transcribing)
        XCTAssertEqual(MeetingRowChip(state: .transcriptFailed), .transcriptFailed)
        XCTAssertEqual(MeetingRowChip(state: .notesFailed), .notesFailed)
    }

    func testShortcutSymbolTextUsesAppleModifierOrder() {
        XCTAssertEqual(KeyboardShortcut.default.symbolText, "⇧⌘Space")
    }

    func testChunkProgressStatusText() {
        let progress = TranscriptionChunkProgress(current: 3, total: 9)
        XCTAssertEqual(progress.statusText, "Part 3 of 9 sent.")
    }

    func testTranscribingStageDetailIncludesChunkProgressWhenPresent() {
        let base = "Audio is uploaded to OpenAI in parts; the text comes back here."
        let withProgress = transcribingStageDetail(base: base, progress: TranscriptionChunkProgress(current: 3, total: 9))
        XCTAssertEqual(withProgress, "Part 3 of 9 sent. \(base)")
    }

    func testTranscribingStageDetailFallsBackToBaseWithNoProgress() {
        let base = "Audio is uploaded to OpenAI in parts; the text comes back here."
        XCTAssertEqual(transcribingStageDetail(base: base, progress: nil), base)
    }

    func testStorageSummaryPluralizesMeetingCount() {
        XCTAssertEqual(MeetingStorageStats.summaryText(meetingCount: 0, audioBytes: nil), "0 meetings")
        XCTAssertEqual(MeetingStorageStats.summaryText(meetingCount: 1, audioBytes: nil), "1 meeting")
        XCTAssertEqual(MeetingStorageStats.summaryText(meetingCount: 14, audioBytes: nil), "14 meetings")
    }

    func testStorageSummaryOmitsAudioSizeWhenNotYetMeasured() {
        // In flight, or failed (e.g. the Meetings directory doesn't exist yet on a fresh
        // install): degrade to just the meeting count rather than showing a fake zero.
        XCTAssertEqual(MeetingStorageStats.summaryText(meetingCount: 3, audioBytes: nil), "3 meetings")
    }

    func testStorageSummaryFormatsAudioBytesWithByteCountFormatter() {
        let bytes: Int64 = 3_400_000_000
        let expected = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)

        XCTAssertEqual(
            MeetingStorageStats.summaryText(meetingCount: 14, audioBytes: bytes),
            "14 meetings · \(expected) of audio"
        )
    }

    private func makeRecord(id: UUID = UUID()) throws -> MeetingRecord {
        MeetingRecord(
            schemaVersion: MeetingRecord.currentSchemaVersion,
            id: id,
            title: "Planning call",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            durationSeconds: 60,
            captureMode: .microphone,
            captureArtifacts: MeetingCaptureArtifacts(
                microphone: try MeetingArtifactReference("audio.m4a"),
                systemAudio: nil,
                transcriptionInput: try MeetingArtifactReference("audio.m4a")
            ),
            transcription: .notStarted,
            transcriptArtifact: nil,
            notes: .notStarted,
            lastValidNotesArtifact: nil,
            notesProvenance: nil
        )
    }
}

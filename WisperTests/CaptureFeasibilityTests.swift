import XCTest
@testable import Wisper

final class CaptureFeasibilityTests: XCTestCase {
    func testMetricsPassWithinReleaseReferenceThresholds() {
        let metrics = CaptureFeasibilityMetrics(
            microphoneStartTime: 10,
            systemStartTime: 10.100,
            microphoneDecodedDuration: 3_600,
            systemDecodedDuration: 3_599.900,
            clippedFrames: 47,
            totalFrames: 48_000,
            droppedBuffers: 0,
            writerBackpressureFailures: 0
        )

        XCTAssertTrue(metrics.meetsReleaseReference())
        XCTAssertEqual(metrics.failures(), [])
    }

    func testClippingThresholdIsExclusive() {
        let metrics = CaptureFeasibilityMetrics(
            microphoneStartTime: 0,
            systemStartTime: 0,
            microphoneDecodedDuration: 60,
            systemDecodedDuration: 60,
            clippedFrames: 1,
            totalFrames: 1_000,
            droppedBuffers: 0,
            writerBackpressureFailures: 0
        )

        XCTAssertEqual(
            metrics.failures(),
            [.clippedFrameRatioExceeded(actual: 0.001, maximumExclusive: 0.001)]
        )
    }

    func testReportsEveryIndependentCaptureFailure() {
        let metrics = CaptureFeasibilityMetrics(
            microphoneStartTime: 0,
            systemStartTime: 0.125,
            microphoneDecodedDuration: 3_600,
            systemDecodedDuration: 3_599.800,
            clippedFrames: 2,
            totalFrames: 1_000,
            droppedBuffers: 3,
            writerBackpressureFailures: 1
        )

        XCTAssertEqual(metrics.failures().count, 5)
        XCTAssertFalse(metrics.meetsReleaseReference())
    }

    func testRejectsMetricsWithoutAValidFrameSample() {
        let metrics = CaptureFeasibilityMetrics(
            microphoneStartTime: 0,
            systemStartTime: 0,
            microphoneDecodedDuration: 0,
            systemDecodedDuration: 0,
            clippedFrames: 0,
            totalFrames: 0,
            droppedBuffers: 0,
            writerBackpressureFailures: 0
        )

        XCTAssertNil(metrics.clippedFrameRatio)
        XCTAssertEqual(metrics.failures(), [.invalidCounters])
    }

    func testAdvertisedImportFormatsMatchProviderContract() {
        XCTAssertEqual(
            Set(RecordingController.supportedAudioFileExtensions),
            Set(["mp3", "mp4", "mpeg", "mpga", "m4a", "wav", "webm"])
        )
        for fileExtension in RecordingController.supportedAudioFileExtensions {
            XCTAssertTrue(RecordingController.isSupportedAudioFile(URL(filePath: "fixture.\(fileExtension)")))
        }
        for removedFormat in ["flac", "ogg", "oga"] {
            XCTAssertFalse(RecordingController.isSupportedAudioFile(URL(filePath: "fixture.\(removedFormat)")))
        }
    }
}

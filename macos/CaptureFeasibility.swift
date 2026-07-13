import Foundation

struct CaptureFeasibilityThresholds: Equatable, Sendable {
    let maximumSourceStartDelta: TimeInterval
    let maximumDecodedDurationDelta: TimeInterval
    let maximumClippedFrameRatio: Double

    static let releaseReference = CaptureFeasibilityThresholds(
        maximumSourceStartDelta: 0.100,
        maximumDecodedDurationDelta: 0.100,
        maximumClippedFrameRatio: 0.001
    )
}

enum CaptureFeasibilityFailure: Equatable, Sendable {
    case invalidCounters
    case sourceStartDeltaExceeded(actual: TimeInterval, maximum: TimeInterval)
    case decodedDurationDeltaExceeded(actual: TimeInterval, maximum: TimeInterval)
    case clippedFrameRatioExceeded(actual: Double, maximumExclusive: Double)
    case droppedBuffers(count: Int)
    case writerBackpressureFailures(count: Int)
}

struct CaptureFeasibilityMetrics: Equatable, Sendable {
    let sourceStartDelta: TimeInterval
    let decodedDurationDelta: TimeInterval
    let clippedFrames: Int
    let totalFrames: Int
    let droppedBuffers: Int
    let writerBackpressureFailures: Int

    init(
        microphoneStartTime: TimeInterval,
        systemStartTime: TimeInterval,
        microphoneDecodedDuration: TimeInterval,
        systemDecodedDuration: TimeInterval,
        clippedFrames: Int,
        totalFrames: Int,
        droppedBuffers: Int,
        writerBackpressureFailures: Int
    ) {
        sourceStartDelta = abs(microphoneStartTime - systemStartTime)
        decodedDurationDelta = abs(microphoneDecodedDuration - systemDecodedDuration)
        self.clippedFrames = clippedFrames
        self.totalFrames = totalFrames
        self.droppedBuffers = droppedBuffers
        self.writerBackpressureFailures = writerBackpressureFailures
    }

    var clippedFrameRatio: Double? {
        guard countersAreValid else { return nil }
        return Double(clippedFrames) / Double(totalFrames)
    }

    func failures(
        thresholds: CaptureFeasibilityThresholds = .releaseReference
    ) -> [CaptureFeasibilityFailure] {
        guard countersAreValid, let clippedFrameRatio else {
            return [.invalidCounters]
        }

        var failures: [CaptureFeasibilityFailure] = []

        if sourceStartDelta > thresholds.maximumSourceStartDelta {
            failures.append(.sourceStartDeltaExceeded(
                actual: sourceStartDelta,
                maximum: thresholds.maximumSourceStartDelta
            ))
        }
        if decodedDurationDelta > thresholds.maximumDecodedDurationDelta {
            failures.append(.decodedDurationDeltaExceeded(
                actual: decodedDurationDelta,
                maximum: thresholds.maximumDecodedDurationDelta
            ))
        }
        if clippedFrameRatio >= thresholds.maximumClippedFrameRatio {
            failures.append(.clippedFrameRatioExceeded(
                actual: clippedFrameRatio,
                maximumExclusive: thresholds.maximumClippedFrameRatio
            ))
        }
        if droppedBuffers > 0 {
            failures.append(.droppedBuffers(count: droppedBuffers))
        }
        if writerBackpressureFailures > 0 {
            failures.append(.writerBackpressureFailures(count: writerBackpressureFailures))
        }

        return failures
    }

    func meetsReleaseReference(
        thresholds: CaptureFeasibilityThresholds = .releaseReference
    ) -> Bool {
        failures(thresholds: thresholds).isEmpty
    }

    private var countersAreValid: Bool {
        totalFrames > 0
            && clippedFrames >= 0
            && clippedFrames <= totalFrames
            && droppedBuffers >= 0
            && writerBackpressureFailures >= 0
    }
}

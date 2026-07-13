import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct SystemAudioCaptureArtifacts: Equatable, Sendable {
    let microphoneURL: URL?
    let systemAudioURL: URL
    let transcriptionInputURL: URL
    let sourceStartDelta: TimeInterval?
    let feasibilityMetrics: CaptureFeasibilityMetrics?
    let droppedBuffers: Int
    let writerBackpressureFailures: Int

    var allURLs: [URL] {
        [microphoneURL, systemAudioURL, transcriptionInputURL]
            .compactMap { $0 }
            .reduce(into: []) { result, url in
                if result.contains(url) == false {
                    result.append(url)
                }
            }
    }
}

@MainActor
protocol SystemAudioCapturing: AnyObject {
    func stop() async throws -> SystemAudioCaptureArtifacts
}

@available(macOS 15.0, *)
@MainActor
final class SystemAudioCaptureController: NSObject, SystemAudioCapturing, SCStreamDelegate {
    private var stream: SCStream?
    private var streamOutput: SystemAudioStreamOutput?
    private var outputURLs: SystemAudioOutputURLs?
    private var includeMicrophone = false
    private var didRequestStop = false
    private var interruptionError: Error?

    func start(
        systemAudioURL: URL,
        microphoneURL: URL?,
        transcriptionInputURL: URL,
        microphoneDeviceID: String?
    ) async throws {
        try ensureScreenRecordingAccess()

        let includeMicrophone = microphoneURL != nil
        let urls = SystemAudioOutputURLs(
            microphone: microphoneURL,
            systemAudio: systemAudioURL,
            transcriptionInput: transcriptionInputURL
        )
        for url in urls.allURLs {
            try? FileManager.default.removeItem(at: url)
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            if Self.isUserDeclinedScreenCaptureError(error) {
                throw SystemAudioCaptureError.screenRecordingPermissionRequired
            }
            throw error
        }
        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplayAvailable
        }

        let currentApp = content.applications.first { application in
            application.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: currentApp.map { [$0] } ?? [],
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureMicrophone = includeMicrophone
        if includeMicrophone, let microphoneDeviceID, microphoneDeviceID.isEmpty == false {
            configuration.microphoneCaptureDeviceID = microphoneDeviceID
        }

        let output = try SystemAudioStreamOutput(urls: urls, includeMicrophone: includeMicrophone)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        if includeMicrophone {
            try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue)
        }

        do {
            try await stream.startCapture()
        } catch {
            try? stream.removeStreamOutput(output, type: .audio)
            if includeMicrophone {
                try? stream.removeStreamOutput(output, type: .microphone)
            }
            output.cancel()
            if Self.isUserDeclinedScreenCaptureError(error) {
                throw SystemAudioCaptureError.screenRecordingPermissionRequired
            }
            throw error
        }

        self.stream = stream
        streamOutput = output
        outputURLs = urls
        self.includeMicrophone = includeMicrophone
        didRequestStop = false
        interruptionError = nil
    }

    func stop() async throws -> SystemAudioCaptureArtifacts {
        guard let stream, let streamOutput, let outputURLs else {
            throw SystemAudioCaptureError.notRecording
        }

        didRequestStop = true
        do {
            try await stream.stopCapture()
            try? stream.removeStreamOutput(streamOutput, type: .audio)
            if includeMicrophone {
                try? stream.removeStreamOutput(streamOutput, type: .microphone)
            }
            if let interruptionError {
                throw interruptionError
            }

            let summary = try await streamOutput.finish()
            let transcriptionURL: URL
            if let microphoneURL = outputURLs.microphone {
                try await Self.exportTranscriptionMix(
                    microphoneURL: microphoneURL,
                    systemAudioURL: outputURLs.systemAudio,
                    outputURL: outputURLs.transcriptionInput,
                    microphoneOffset: summary.microphoneOffset,
                    systemOffset: summary.systemOffset
                )
                transcriptionURL = outputURLs.transcriptionInput
            } else {
                transcriptionURL = outputURLs.systemAudio
            }

            let result = SystemAudioCaptureArtifacts(
                microphoneURL: outputURLs.microphone,
                systemAudioURL: outputURLs.systemAudio,
                transcriptionInputURL: transcriptionURL,
                sourceStartDelta: summary.sourceStartDelta,
                feasibilityMetrics: try await Self.feasibilityMetrics(
                    summary: summary,
                    microphoneURL: outputURLs.microphone,
                    systemAudioURL: outputURLs.systemAudio
                ),
                droppedBuffers: summary.droppedBuffers,
                writerBackpressureFailures: summary.writerBackpressureFailures
            )
            if let metrics = result.feasibilityMetrics {
                LocalLogger.shared.info("System audio capture metrics", metadata: [
                    "sourceStartDelta": String(metrics.sourceStartDelta),
                    "decodedDurationDelta": String(metrics.decodedDurationDelta),
                    "clippedFrameRatio": String(metrics.clippedFrameRatio ?? -1),
                    "droppedBuffers": String(metrics.droppedBuffers),
                    "writerBackpressureFailures": String(metrics.writerBackpressureFailures),
                    "meetsReleaseReference": String(metrics.meetsReleaseReference())
                ])
            }
            reset()
            return result
        } catch {
            streamOutput.cancel()
            for url in outputURLs.allURLs {
                try? FileManager.default.removeItem(at: url)
            }
            reset()
            throw Self.normalizedRecordingError(error)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard didRequestStop == false else { return }
            interruptionError = error
        }
    }

    private func reset() {
        stream = nil
        streamOutput = nil
        outputURLs = nil
        includeMicrophone = false
        didRequestStop = false
        interruptionError = nil
    }

    private func ensureScreenRecordingAccess() throws {
        guard ScreenAudioPermission.status() != .granted else { return }
        if ScreenAudioPermission.requestAccess() == false {
            throw SystemAudioCaptureError.screenRecordingPermissionRequired
        }
    }

    private static func exportTranscriptionMix(
        microphoneURL: URL,
        systemAudioURL: URL,
        outputURL: URL,
        microphoneOffset: CMTime,
        systemOffset: CMTime
    ) async throws {
        let microphoneAsset = AVURLAsset(url: microphoneURL)
        let systemAsset = AVURLAsset(url: systemAudioURL)
        guard let microphoneSource = try await microphoneAsset.loadTracks(withMediaType: .audio).first,
              let systemSource = try await systemAsset.loadTracks(withMediaType: .audio).first else {
            throw SystemAudioCaptureError.recordingFinalizationFailed
        }

        let composition = AVMutableComposition()
        guard let microphoneTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let systemTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw SystemAudioCaptureError.recordingFinalizationFailed
        }

        let microphoneDuration = try await microphoneAsset.load(.duration)
        let systemDuration = try await systemAsset.load(.duration)
        try microphoneTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: microphoneDuration),
            of: microphoneSource,
            at: microphoneOffset
        )
        try systemTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: systemDuration),
            of: systemSource,
            at: systemOffset
        )

        let microphoneParameters = AVMutableAudioMixInputParameters(track: microphoneTrack)
        microphoneParameters.setVolume(0.5, at: .zero)
        let systemParameters = AVMutableAudioMixInputParameters(track: systemTrack)
        systemParameters.setVolume(0.5, at: .zero)
        let mix = AVMutableAudioMix()
        mix.inputParameters = [microphoneParameters, systemParameters]

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw SystemAudioCaptureError.recordingFinalizationFailed
        }
        try? FileManager.default.removeItem(at: outputURL)
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.audioMix = mix
        let exporterBox = SendableExportSessionBox(exporter)
        try await withCheckedThrowingContinuation { continuation in
            exporterBox.session.exportAsynchronously {
                let exporter = exporterBox.session
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .cancelled, .failed:
                    continuation.resume(throwing: exporter.error ?? SystemAudioCaptureError.recordingFinalizationFailed)
                default:
                    continuation.resume(throwing: SystemAudioCaptureError.recordingFinalizationFailed)
                }
            }
        }
    }

    private static func feasibilityMetrics(
        summary: SystemAudioWriterSummary,
        microphoneURL: URL?,
        systemAudioURL: URL
    ) async throws -> CaptureFeasibilityMetrics? {
        guard let microphoneURL, let sourceStartDelta = summary.sourceStartDelta else { return nil }
        let microphoneDuration = try await AVURLAsset(url: microphoneURL).load(.duration).seconds
        let systemDuration = try await AVURLAsset(url: systemAudioURL).load(.duration).seconds
        return CaptureFeasibilityMetrics(
            microphoneStartTime: 0,
            systemStartTime: sourceStartDelta,
            microphoneDecodedDuration: microphoneDuration,
            systemDecodedDuration: systemDuration,
            clippedFrames: summary.clippedFrames,
            totalFrames: summary.totalFrames,
            droppedBuffers: summary.droppedBuffers,
            writerBackpressureFailures: summary.writerBackpressureFailures
        )
    }

    private static func isUserDeclinedScreenCaptureError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain && nsError.code == -3_801
    }

    private static func normalizedRecordingError(_ error: Error) -> Error {
        if let captureError = error as? SystemAudioCaptureError {
            return captureError
        }
        let nsError = error as NSError
        if nsError.domain.contains("ReplayKit") {
            return SystemAudioCaptureError.recordingFinalizationFailed
        }
        return error
    }
}

private struct SystemAudioOutputURLs: Sendable {
    let microphone: URL?
    let systemAudio: URL
    let transcriptionInput: URL

    var allURLs: [URL] {
        [microphone, systemAudio, transcriptionInput].compactMap { $0 }
    }
}

@available(macOS 15.0, *)
private final class SystemAudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.wisper.capture.audio-writers", qos: .userInitiated)

    private let microphoneWriter: RealtimeAudioWriter?
    private let systemWriter: RealtimeAudioWriter
    private let lock = NSLock()
    private var firstMicrophonePTS: CMTime?
    private var firstSystemPTS: CMTime?
    private var droppedBuffers = 0
    private var clippedFrames = 0
    private var totalFrames = 0

    init(urls: SystemAudioOutputURLs, includeMicrophone: Bool) throws {
        systemWriter = try RealtimeAudioWriter(outputURL: urls.systemAudio, channels: 2)
        if includeMicrophone, let microphoneURL = urls.microphone {
            microphoneWriter = try RealtimeAudioWriter(outputURL: microphoneURL, channels: 1)
        } else {
            microphoneWriter = nil
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else {
            lock.withLock { droppedBuffers += 1 }
            return
        }

        let pts = sampleBuffer.presentationTimeStamp
        let levels = Self.audioLevels(in: sampleBuffer)
        lock.withLock {
            clippedFrames += levels.clippedFrames
            totalFrames += levels.totalFrames
        }
        do {
            switch type {
            case .audio:
                lock.withLock {
                    if firstSystemPTS == nil { firstSystemPTS = pts }
                }
                try systemWriter.append(sampleBuffer)
            case .microphone:
                lock.withLock {
                    if firstMicrophonePTS == nil { firstMicrophonePTS = pts }
                }
                try microphoneWriter?.append(sampleBuffer)
            default:
                break
            }
        } catch {
            lock.withLock { droppedBuffers += 1 }
        }
    }

    func finish() async throws -> SystemAudioWriterSummary {
        let system = try await systemWriter.finish()
        let microphone = try await microphoneWriter?.finish()
        let timing = lock.withLock {
            (firstMicrophonePTS, firstSystemPTS, droppedBuffers, clippedFrames, totalFrames)
        }

        let sourceStartDelta: TimeInterval?
        let microphoneOffset: CMTime
        let systemOffset: CMTime
        if let microphonePTS = timing.0, let systemPTS = timing.1 {
            sourceStartDelta = abs(CMTimeGetSeconds(CMTimeSubtract(microphonePTS, systemPTS)))
            let earliest = CMTimeMinimum(microphonePTS, systemPTS)
            microphoneOffset = CMTimeSubtract(microphonePTS, earliest)
            systemOffset = CMTimeSubtract(systemPTS, earliest)
        } else {
            sourceStartDelta = nil
            microphoneOffset = .zero
            systemOffset = .zero
        }

        return SystemAudioWriterSummary(
            sourceStartDelta: sourceStartDelta,
            microphoneOffset: microphoneOffset,
            systemOffset: systemOffset,
            droppedBuffers: timing.2,
            clippedFrames: timing.3,
            totalFrames: timing.4,
            writerBackpressureFailures: system.backpressureFailures + (microphone?.backpressureFailures ?? 0)
        )
    }

    private static func audioLevels(in sampleBuffer: CMSampleBuffer) -> (clippedFrames: Int, totalFrames: Int) {
        guard let format = sampleBuffer.formatDescription,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM else {
            return (0, 0)
        }
        let frameCount = sampleBuffer.numSamples
        guard frameCount > 0 else { return (0, 0) }

        var requiredSize = 0
        var retainedBlockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &retainedBlockBuffer
        ) == noErr else { return (0, 0) }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let bufferList = storage.assumingMemoryBound(to: AudioBufferList.self)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &retainedBlockBuffer
        ) == noErr else { return (0, 0) }

        var clipped = Array(repeating: false, count: frameCount)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = Int(description.mBitsPerChannel)
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let availableSamples = Int(buffer.mDataByteSize) / max(bits / 8, 1)
            let frames = min(frameCount, availableSamples / channels)
            for frame in 0..<frames where clipped[frame] == false {
                for channel in 0..<channels {
                    let index = frame * channels + channel
                    let isClipped: Bool
                    switch (isFloat, bits) {
                    case (true, 32):
                        isClipped = abs(data.assumingMemoryBound(to: Float.self)[index]) >= 1
                    case (true, 64):
                        isClipped = abs(data.assumingMemoryBound(to: Double.self)[index]) >= 1
                    case (false, 16):
                        let value = data.assumingMemoryBound(to: Int16.self)[index]
                        isClipped = value == .min || value == .max
                    case (false, 32):
                        let value = data.assumingMemoryBound(to: Int32.self)[index]
                        isClipped = value == .min || value == .max
                    default:
                        isClipped = false
                    }
                    if isClipped {
                        clipped[frame] = true
                        break
                    }
                }
            }
        }
        return (clipped.lazy.filter { $0 }.count, frameCount)
    }

    func cancel() {
        systemWriter.cancel()
        microphoneWriter?.cancel()
    }
}

private struct RealtimeAudioWriterSummary: Sendable {
    let backpressureFailures: Int
}

private struct SystemAudioWriterSummary: Sendable {
    let sourceStartDelta: TimeInterval?
    let microphoneOffset: CMTime
    let systemOffset: CMTime
    let droppedBuffers: Int
    let clippedFrames: Int
    let totalFrames: Int
    let writerBackpressureFailures: Int
}

private final class RealtimeAudioWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let lock = NSLock()
    private var didStartSession = false
    private var didFinish = false
    private var backpressureFailures = 0

    init(outputURL: URL, channels: Int) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw SystemAudioCaptureError.recordingFinalizationFailed
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? SystemAudioCaptureError.recordingFinalizationFailed
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) throws {
        try lock.withLock {
            guard didFinish == false else { return }
            if didStartSession == false {
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                didStartSession = true
            }
            guard input.isReadyForMoreMediaData else {
                backpressureFailures += 1
                return
            }
            guard input.append(sampleBuffer) else {
                throw writer.error ?? SystemAudioCaptureError.recordingFinalizationFailed
            }
        }
    }

    func finish() async throws -> RealtimeAudioWriterSummary {
        let summary = try lock.withLock { () throws -> RealtimeAudioWriterSummary in
            guard didStartSession else {
                throw SystemAudioCaptureError.noAudioSamples
            }
            guard didFinish == false else {
                return RealtimeAudioWriterSummary(backpressureFailures: backpressureFailures)
            }
            didFinish = true
            input.markAsFinished()
            return RealtimeAudioWriterSummary(backpressureFailures: backpressureFailures)
        }

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw writer.error ?? SystemAudioCaptureError.recordingFinalizationFailed
        }
        return summary
    }

    func cancel() {
        lock.withLock {
            guard didFinish == false else { return }
            didFinish = true
            writer.cancelWriting()
        }
    }
}

enum SystemAudioCaptureError: LocalizedError, Equatable {
    case noDisplayAvailable
    case noAudioSamples
    case notRecording
    case screenRecordingPermissionRequired
    case recordingFinalizationFailed

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            "macOS did not return a display for system audio capture."
        case .noAudioSamples:
            "No audio samples were captured. Play audio and try recording again."
        case .notRecording:
            "System audio capture is not recording."
        case .screenRecordingPermissionRequired:
            "Approve Wisper in System Settings > Privacy & Security > Screen & System Audio Recording, then start recording again."
        case .recordingFinalizationFailed:
            "System audio recording could not be saved. Try again, or switch to Microphone mode if this keeps happening."
        }
    }
}

import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
protocol SystemAudioCapturing: AnyObject {
    func stop() async throws -> URL
}

@available(macOS 15.0, *)
@MainActor
final class SystemAudioCaptureController: NSObject, SystemAudioCapturing, SCRecordingOutputDelegate, SCStreamDelegate {
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var stopContinuation: CheckedContinuation<URL, Error>?
    private var didRequestStop = false

    func start(outputURL: URL, includeMicrophone: Bool, microphoneDeviceID: String?) async throws {
        try ensureScreenRecordingAccess()

        try? FileManager.default.removeItem(at: outputURL)

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

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.outputFileType = .mp4

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        try stream.addRecordingOutput(recordingOutput)
        do {
            try await stream.startCapture()
        } catch {
            if Self.isUserDeclinedScreenCaptureError(error) {
                throw SystemAudioCaptureError.screenRecordingPermissionRequired
            }
            throw error
        }

        self.stream = stream
        self.recordingOutput = recordingOutput
        self.outputURL = outputURL
        didRequestStop = false
    }

    func stop() async throws -> URL {
        guard let stream, let recordingOutput, outputURL != nil else {
            throw SystemAudioCaptureError.notRecording
        }

        didRequestStop = true
        defer {
            try? stream.removeRecordingOutput(recordingOutput)
            self.stream = nil
            self.recordingOutput = nil
            self.outputURL = nil
            didRequestStop = false
        }

        return try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
            Task {
                do {
                    try await stream.stopCapture()
                } catch {
                    self.finishStopping(throwing: error)
                }
            }
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard let outputURL else { return }
            finishStopping(returning: outputURL)
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            finishStopping(throwing: error)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard didRequestStop == false else { return }
            let continuation = stopContinuation
            stopContinuation = nil
            continuation?.resume(throwing: error)
        }
    }

    private func finishStopping(returning outputURL: URL) {
        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume(returning: outputURL)
    }

    private func finishStopping(throwing error: Error) {
        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume(throwing: Self.normalizedRecordingError(error))
    }

    private func ensureScreenRecordingAccess() throws {
        guard ScreenAudioPermission.status() != .granted else { return }

        if ScreenAudioPermission.requestAccess() == false {
            throw SystemAudioCaptureError.screenRecordingPermissionRequired
        }
    }

    private static func isUserDeclinedScreenCaptureError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain && nsError.code == -3_801
    }

    private static func normalizedRecordingError(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain.contains("ReplayKit") {
            return SystemAudioCaptureError.recordingFinalizationFailed
        }

        return error
    }
}

enum SystemAudioCaptureError: LocalizedError, Equatable {
    case noDisplayAvailable
    case notRecording
    case screenRecordingPermissionRequired
    case recordingFinalizationFailed

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            "macOS did not return a display for system audio capture."
        case .notRecording:
            "System audio capture is not recording."
        case .screenRecordingPermissionRequired:
            "Approve Wisper in System Settings > Privacy & Security > Screen & System Audio Recording, then start recording again."
        case .recordingFinalizationFailed:
            "System audio recording could not be saved. Try again, or switch to Microphone mode if this keeps happening."
        }
    }
}

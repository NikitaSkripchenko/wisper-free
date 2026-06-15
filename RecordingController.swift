import AVFoundation
import Foundation

struct AudioInputSource: Identifiable, Equatable {
    let id: String
    let name: String
}

enum RecordingPhase: String {
    case idle = "Idle"
    case recording = "Recording"
    case paused = "Paused"
}

@MainActor
final class RecordingController: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published private(set) var phase: RecordingPhase = .idle
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var lastDurationSeconds: TimeInterval = 0
    @Published private(set) var audioSources: [AudioInputSource] = []
    @Published private(set) var lastRecordingSourceName = "Microphone"

    private var captureSession: AVCaptureSession?
    private var movieOutput: AVCaptureMovieFileOutput?
    private var timer: Timer?
    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedDuration: TimeInterval = 0
    private var pendingMovieURL: URL?
    private var pendingAudioURL: URL?
    private var discardWhenFinished = false
    private var stopContinuation: CheckedContinuation<URL?, Error>?

    var isRecording: Bool {
        phase == .recording || phase == .paused
    }

    var isPaused: Bool {
        phase == .paused
    }

    var elapsedDisplay: String {
        let totalSeconds = Int(elapsedSeconds)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    func refreshAudioSources() {
        audioSources = Self.fetchAudioSources()
    }

    func audioSourceName(for sourceID: String?) -> String {
        if let sourceID, let source = audioSources.first(where: { $0.id == sourceID }) {
            return source.name
        }

        return Self.defaultAudioDevice()?.localizedName ?? "System Default"
    }

    func start(audioSourceID: String?) async throws {
        guard phase == .idle else { return }

        let granted = await Self.requestMicrophoneAccess()
        guard granted else {
            throw RecordingError.microphoneAccessDenied
        }

        refreshAudioSources()

        guard let device = Self.audioDevice(for: audioSourceID) else {
            throw RecordingError.audioSourceUnavailable
        }

        let urls = try Self.makeRecordingURLs()
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureMovieFileOutput()

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw RecordingError.audioSourceUnavailable
        }
        session.addInput(input)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecordingError.captureUnavailable
        }
        session.addOutput(output)
        session.commitConfiguration()

        try? FileManager.default.removeItem(at: urls.movie)
        try? FileManager.default.removeItem(at: urls.audio)

        captureSession = session
        movieOutput = output
        pendingMovieURL = urls.movie
        pendingAudioURL = urls.audio
        discardWhenFinished = false
        lastRecordingURL = urls.audio
        lastRecordingSourceName = device.localizedName
        startedAt = Date()
        pausedAt = nil
        pausedDuration = 0
        elapsedSeconds = 0
        lastDurationSeconds = 0

        session.startRunning()
        output.startRecording(to: urls.movie, recordingDelegate: self)

        phase = .recording
        startTimer()
    }

    func stop(discarding: Bool = false) async throws -> URL? {
        guard phase != .idle else {
            if discarding, let lastRecordingURL {
                try? FileManager.default.removeItem(at: lastRecordingURL)
                self.lastRecordingURL = nil
            }
            return lastRecordingURL
        }

        updateElapsedTime()
        lastDurationSeconds = elapsedSeconds
        discardWhenFinished = discarding

        guard let movieOutput, movieOutput.isRecording else {
            cleanupAfterStop()
            return discarding ? nil : lastRecordingURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
            movieOutput.stopRecording()
        }
    }

    func pause() {
        guard phase == .recording else { return }
        movieOutput?.pauseRecording()
        pausedAt = Date()
        phase = .paused
        updateElapsedTime()
    }

    func resume() {
        guard phase == .paused else { return }
        if let pausedAt {
            pausedDuration += Date().timeIntervalSince(pausedAt)
        }
        pausedAt = nil
        movieOutput?.resumeRecording()
        phase = .recording
        updateElapsedTime()
    }

    func discard() async throws {
        _ = try await stop(discarding: true)
        lastRecordingURL = nil
        lastDurationSeconds = 0
        elapsedSeconds = 0
    }

    func restart(audioSourceID: String?) async throws {
        try await discard()
        try await start(audioSourceID: audioSourceID)
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            await self.finishRecording(outputFileURL: outputFileURL, error: error)
        }
    }

    private func finishRecording(outputFileURL: URL, error: Error?) async {
        let continuation = stopContinuation
        stopContinuation = nil

        defer {
            cleanupAfterStop()
        }

        if discardWhenFinished {
            try? FileManager.default.removeItem(at: outputFileURL)
            if let pendingAudioURL {
                try? FileManager.default.removeItem(at: pendingAudioURL)
            }
            lastRecordingURL = nil
            continuation?.resume(returning: nil)
            return
        }

        if let error {
            removePendingFiles(outputFileURL: outputFileURL)
            continuation?.resume(throwing: error)
            return
        }

        guard let pendingAudioURL else {
            continuation?.resume(returning: outputFileURL)
            return
        }

        do {
            try await Self.exportAudio(from: outputFileURL, to: pendingAudioURL)
            try? FileManager.default.removeItem(at: outputFileURL)
            lastRecordingURL = pendingAudioURL
            continuation?.resume(returning: pendingAudioURL)
        } catch {
            removePendingFiles(outputFileURL: outputFileURL)
            continuation?.resume(throwing: error)
        }
    }

    private func removePendingFiles(outputFileURL: URL) {
        try? FileManager.default.removeItem(at: outputFileURL)
        if let pendingAudioURL {
            try? FileManager.default.removeItem(at: pendingAudioURL)
            if lastRecordingURL == pendingAudioURL {
                lastRecordingURL = nil
            }
        }
    }

    private func cleanupAfterStop() {
        captureSession?.stopRunning()
        captureSession = nil
        movieOutput = nil
        timer?.invalidate()
        timer = nil
        startedAt = nil
        pausedAt = nil
        pausedDuration = 0
        pendingMovieURL = nil
        pendingAudioURL = nil
        discardWhenFinished = false
        phase = .idle
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateElapsedTime()
            }
        }
    }

    private func updateElapsedTime() {
        guard let startedAt else { return }
        let endDate = pausedAt ?? Date()
        elapsedSeconds = max(0, endDate.timeIntervalSince(startedAt) - pausedDuration)
    }

    private static func requestMicrophoneAccess() async -> Bool {
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return true
            case .undetermined:
                return await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
            case .denied:
                return false
            @unknown default:
                return false
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static func fetchAudioSources() -> [AudioInputSource] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        var seenIDs = Set<String>()
        return discoverySession.devices.compactMap { device in
            guard seenIDs.insert(device.uniqueID).inserted else { return nil }
            return AudioInputSource(id: device.uniqueID, name: device.localizedName)
        }
    }

    private static func audioDevice(for sourceID: String?) -> AVCaptureDevice? {
        if let sourceID, sourceID.isEmpty == false {
            return AVCaptureDevice(uniqueID: sourceID)
        }

        return defaultAudioDevice()
    }

    private static func defaultAudioDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(for: .audio)
    }

    private static func makeRecordingURLs() throws -> (movie: URL, audio: URL) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Wisper/Recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let filename = "Recording-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-"))"
        return (
            movie: directory.appending(path: "\(filename)-capture").appendingPathExtension("mov"),
            audio: directory.appending(path: filename).appendingPathExtension("m4a")
        )
    }

    private static func exportAudio(from sourceURL: URL, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecordingError.exportUnavailable
        }

        try? FileManager.default.removeItem(at: outputURL)
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a

        try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: exportSession.error ?? RecordingError.exportFailed)
                default:
                    continuation.resume(throwing: RecordingError.exportFailed)
                }
            }
        }
    }
}

enum RecordingError: LocalizedError {
    case microphoneAccessDenied
    case audioSourceUnavailable
    case captureUnavailable
    case exportUnavailable
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .microphoneAccessDenied:
            "Microphone access is disabled. Enable it in System Settings > Privacy & Security > Microphone."
        case .audioSourceUnavailable:
            "The selected audio source is unavailable. Choose another source in Settings."
        case .captureUnavailable:
            "macOS could not prepare this audio source for recording."
        case .exportUnavailable:
            "macOS could not prepare the recording for transcription."
        case .exportFailed:
            "Audio export failed. Try recording again."
        }
    }
}

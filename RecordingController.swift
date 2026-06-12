import AVFoundation
import Foundation

enum RecordingPhase: String {
    case idle = "Idle"
    case recording = "Recording"
    case paused = "Paused"
}

@MainActor
final class RecordingController: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var phase: RecordingPhase = .idle
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var lastDurationSeconds: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedDuration: TimeInterval = 0

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

    func start() async throws {
        guard phase == .idle else { return }

        let granted = await Self.requestMicrophoneAccess()
        guard granted else {
            throw RecordingError.microphoneAccessDenied
        }

        let url = try Self.makeRecordingURL()
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let nextRecorder = try AVAudioRecorder(url: url, settings: settings)
        nextRecorder.delegate = self
        nextRecorder.isMeteringEnabled = true
        nextRecorder.prepareToRecord()
        nextRecorder.record()

        recorder = nextRecorder
        lastRecordingURL = url
        startedAt = Date()
        pausedAt = nil
        pausedDuration = 0
        elapsedSeconds = 0
        lastDurationSeconds = 0
        phase = .recording
        startTimer()
    }

    func stop() -> URL? {
        guard phase != .idle else { return lastRecordingURL }
        updateElapsedTime()
        lastDurationSeconds = elapsedSeconds
        recorder?.stop()
        cleanupAfterStop()
        return lastRecordingURL
    }

    func pause() {
        guard phase == .recording else { return }
        recorder?.pause()
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
        recorder?.record()
        phase = .recording
        updateElapsedTime()
    }

    func discard() {
        let url = lastRecordingURL
        _ = stop()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        lastRecordingURL = nil
        lastDurationSeconds = 0
        elapsedSeconds = 0
    }

    func restart() async throws {
        discard()
        try await start()
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            self.cleanupAfterStop()
        }
    }

    private func cleanupAfterStop() {
        recorder = nil
        timer?.invalidate()
        timer = nil
        startedAt = nil
        pausedAt = nil
        pausedDuration = 0
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
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }

    private static func makeRecordingURL() throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Wisper/Recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let filename = "Recording-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-"))"
        return directory.appending(path: filename).appendingPathExtension("m4a")
    }
}

enum RecordingError: LocalizedError {
    case microphoneAccessDenied

    var errorDescription: String? {
        switch self {
        case .microphoneAccessDenied:
            "Microphone access is disabled. Enable it in System Settings > Privacy & Security > Microphone."
        }
    }
}

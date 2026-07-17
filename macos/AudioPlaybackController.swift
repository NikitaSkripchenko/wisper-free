import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioPlaybackController: NSObject, ObservableObject {
    @Published private(set) var loadedURL: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

    func toggle(url: URL) throws {
        try load(url: url)
        try togglePlayback()
    }

    func load(url: URL) throws {
        guard loadedURL != url || player == nil else { return }

        stopProgressTimer()
        let nextPlayer = try AVAudioPlayer(contentsOf: url)
        nextPlayer.prepareToPlay()
        player = nextPlayer
        loadedURL = url
        duration = nextPlayer.duration.isFinite ? max(0, nextPlayer.duration) : 0
        currentTime = 0
        isPlaying = false
    }

    func togglePlayback() throws {
        if isPlaying {
            pause()
        } else {
            try play()
        }
    }

    func play() throws {
        guard let player else { return }
        if duration > 0, currentTime >= duration {
            player.currentTime = 0
            currentTime = 0
        }
        guard player.play() else {
            throw AudioPlaybackError.couldNotPlay
        }
        isPlaying = true
        startProgressTimer()
    }

    func pause() {
        guard let player else { return }
        player.pause()
        currentTime = player.currentTime
        isPlaying = false
        stopProgressTimer()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, time), duration)
        player.currentTime = clamped
        currentTime = clamped
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        currentTime = 0
        isPlaying = false
        stopProgressTimer()
    }

    var elapsedText: String {
        Self.timeText(currentTime)
    }

    var durationText: String {
        Self.timeText(duration)
    }

    static func timeText(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateProgress()
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func updateProgress() {
        guard let player else {
            stopProgressTimer()
            return
        }

        currentTime = min(player.currentTime, duration)
        guard player.isPlaying == false else { return }

        isPlaying = false
        stopProgressTimer()
    }
}

private enum AudioPlaybackError: LocalizedError {
    case couldNotPlay

    var errorDescription: String? {
        "This audio could not be played."
    }
}

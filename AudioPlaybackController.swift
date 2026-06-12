import AVFoundation
import Foundation

@MainActor
final class AudioPlaybackController: ObservableObject {
    @Published private(set) var playingURL: URL?

    private var player: AVAudioPlayer?

    func toggle(url: URL) throws {
        if playingURL == url, player?.isPlaying == true {
            stop()
            return
        }

        player = try AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        player?.play()
        playingURL = url
    }

    func stop() {
        player?.stop()
        player = nil
        playingURL = nil
    }
}

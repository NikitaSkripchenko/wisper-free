import AVFoundation
import Foundation

struct AudioChunker: AudioChunking {
    func duration(of audioURL: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: audioURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw AudioChunkingError.invalidDuration
        }
        return duration
    }

    func split(audioURL: URL, chunkSeconds: Int, outputDirectory: URL) async throws -> [URL] {
        guard chunkSeconds > 0 else {
            throw AudioChunkingError.invalidChunkLength
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let asset = AVURLAsset(url: audioURL)
        let totalDuration = try await duration(of: audioURL)
        let chunkDuration = TimeInterval(chunkSeconds)
        let chunkCount = Int(ceil(totalDuration / chunkDuration))

        guard chunkCount > 0 else {
            throw AudioChunkingError.noChunksCreated
        }

        var chunkURLs: [URL] = []
        for index in 0..<chunkCount {
            let startSeconds = TimeInterval(index) * chunkDuration
            let remainingSeconds = totalDuration - startSeconds
            let currentDuration = min(chunkDuration, remainingSeconds)
            let chunkURL = outputDirectory.appending(path: String(format: "chunk_%03d.m4a", index))

            try? FileManager.default.removeItem(at: chunkURL)
            try await exportChunk(
                asset: asset,
                startSeconds: startSeconds,
                durationSeconds: currentDuration,
                outputURL: chunkURL
            )
            chunkURLs.append(chunkURL)
        }

        if chunkURLs.isEmpty {
            throw AudioChunkingError.noChunksCreated
        }

        return chunkURLs
    }

    private func exportChunk(asset: AVAsset, startSeconds: TimeInterval, durationSeconds: TimeInterval, outputURL: URL) async throws {
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioChunkingError.exportUnavailable
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: durationSeconds, preferredTimescale: 600)
        )

        let exportSessionBox = SendableExportSessionBox(exportSession)
        try await withCheckedThrowingContinuation { continuation in
            exportSessionBox.session.exportAsynchronously {
                let session = exportSessionBox.session
                switch session.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: session.error ?? AudioChunkingError.exportFailed)
                default:
                    continuation.resume(throwing: AudioChunkingError.exportFailed)
                }
            }
        }
    }
}

final class SendableExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}

enum AudioChunkingError: LocalizedError {
    case invalidDuration
    case invalidChunkLength
    case exportUnavailable
    case exportFailed
    case noChunksCreated

    var errorDescription: String? {
        switch self {
        case .invalidDuration:
            "Could not determine the audio duration for chunking."
        case .invalidChunkLength:
            "Chunk length must be a positive number of seconds."
        case .exportUnavailable:
            "macOS could not prepare this audio file for chunking."
        case .exportFailed:
            "Audio chunk export failed."
        case .noChunksCreated:
            "No audio chunks were created."
        }
    }
}

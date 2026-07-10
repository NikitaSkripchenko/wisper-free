import Foundation
import OpenAI

enum TranscriptionMode: String, Sendable {
    case plain
    case chunked
}

struct TranscriptionResult: Sendable {
    let mode: TranscriptionMode
    let text: String
}

enum TranscriptionProgress: Sendable {
    case chunkingStart
    case chunkingComplete(total: Int)
    case transcriptionStart(label: String)
    case transcriptionComplete(label: String)
    case chunkComplete(current: Int, total: Int)
}

protocol AudioChunking: Sendable {
    func duration(of audioURL: URL) async throws -> TimeInterval
    func split(audioURL: URL, chunkSeconds: Int, outputDirectory: URL) async throws -> [URL]
}

protocol AudioTranscriptionClient: Sendable {
    func transcribe(audioURL: URL, apiKey: String) async throws -> String
}

struct OpenAISDKTranscriptionClient: AudioTranscriptionClient {
    private let model: Model

    init(model: Model = "gpt-4o-transcribe") {
        self.model = model
    }

    func transcribe(audioURL: URL, apiKey: String) async throws -> String {
        let audioData = try Data(contentsOf: audioURL)
        let client = OpenAI(apiToken: apiKey)
        let query = AudioTranscriptionQuery(
            file: audioData,
            fileType: try fileType(for: audioURL),
            model: model
        )
        let result = try await client.audioTranscriptions(query: query)
        return result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    private func fileType(for audioURL: URL) throws -> AudioTranscriptionQuery.FileType {
        switch audioURL.pathExtension.lowercased() {
        case "flac":
            .flac
        case "m4a":
            .m4a
        case "mp3":
            .mp3
        case "mp4":
            .mp4
        case "mpeg":
            .mpeg
        case "mpga":
            .mpga
        case "ogg", "oga":
            .ogg
        case "wav":
            .wav
        case "webm":
            .webm
        default:
            throw TranscriptionError.unsupportedAudioFileType(audioURL.pathExtension)
        }
    }
}

enum TranscriptionError: LocalizedError {
    case unsupportedAudioFileType(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedAudioFileType(let fileExtension):
            "OpenAI transcription does not support .\(fileExtension) files in this SDK build."
        }
    }
}

struct OpenAITranscriptionService {
    private let chunker: any AudioChunking
    private let client: any AudioTranscriptionClient

    init(
        chunker: any AudioChunking = AudioChunker(),
        client: any AudioTranscriptionClient = OpenAISDKTranscriptionClient()
    ) {
        self.chunker = chunker
        self.client = client
    }

    func transcribe(audioURL: URL, apiKey: String) async throws -> String {
        try await transcribe(audioURL: audioURL, apiKey: apiKey, chunkSeconds: nil).text
    }

    func transcribe(
        audioURL: URL,
        apiKey: String,
        chunkSeconds: Int?,
        progress: (@MainActor (TranscriptionProgress) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        if let chunkSeconds, chunkSeconds > 0 {
            let duration = try await chunker.duration(of: audioURL)

            if duration > TimeInterval(chunkSeconds) {
                let outputDirectory = FileManager.default.temporaryDirectory
                    .appending(path: "WisperChunks-\(UUID().uuidString)", directoryHint: .isDirectory)
                defer { try? FileManager.default.removeItem(at: outputDirectory) }

                await progress?(.chunkingStart)
                let chunks = try await chunker.split(
                    audioURL: audioURL,
                    chunkSeconds: chunkSeconds,
                    outputDirectory: outputDirectory
                )
                await progress?(.chunkingComplete(total: chunks.count))

                var chunkTexts: [String] = []
                for (index, chunkURL) in chunks.enumerated() {
                    let label = "chunk \(index + 1)/\(chunks.count)"
                    await progress?(.transcriptionStart(label: label))
                    let text = try await transcribeSingleFile(audioURL: chunkURL, apiKey: apiKey)
                    await progress?(.transcriptionComplete(label: label))
                    chunkTexts.append(text)
                    await progress?(.chunkComplete(current: index + 1, total: chunks.count))
                }

                let stitchedText = chunkTexts
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.isEmpty == false }
                    .joined(separator: "\n\n")
                return TranscriptionResult(mode: .chunked, text: stitchedText)
            }
        }

        await progress?(.transcriptionStart(label: audioURL.lastPathComponent))
        let text = try await transcribeSingleFile(audioURL: audioURL, apiKey: apiKey)
        await progress?(.transcriptionComplete(label: audioURL.lastPathComponent))
        return TranscriptionResult(mode: .plain, text: text)
    }

    private func transcribeSingleFile(audioURL: URL, apiKey: String) async throws -> String {
        try await client.transcribe(audioURL: audioURL, apiKey: apiKey)
    }
}

import Foundation
import OpenAI

enum TranscriptionMode: String, Codable, Equatable, Sendable {
    case plain
    case chunked
}

struct TranscriptionResult: Sendable {
    let mode: TranscriptionMode
    let text: String
    let requestCount: Int

    init(mode: TranscriptionMode, text: String, requestCount: Int = 1) {
        self.mode = mode
        self.text = text
        self.requestCount = requestCount
    }
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

protocol AudioFileSizing: Sendable {
    func size(of url: URL) throws -> Int64
}

struct LocalAudioFileSizer: AudioFileSizing {
    func size(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw TranscriptionError.audioNormalizationUnsupported
        }
        return Int64(size)
    }
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
    case audioNormalizationUnsupported
    case audioTooLarge
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .unsupportedAudioFileType(let fileExtension):
            "OpenAI transcription does not support .\(fileExtension) files in this SDK build."
        case .audioNormalizationUnsupported:
            "This audio file could not be normalized for safe upload."
        case .audioTooLarge:
            "This audio file could not be split below the upload safety limit."
        case .emptyResult:
            "No speech was recognized in this recording."
        }
    }
}

struct OpenAITranscriptionService: Sendable {
    static let maximumTransportBytes: Int64 = 24 * 1_024 * 1_024
    static let minimumChunkSeconds = 30
    static let maximumConcurrentRequests = 2

    private let chunker: any AudioChunking
    private let client: any AudioTranscriptionClient
    private let fileSizer: any AudioFileSizing

    init(
        chunker: any AudioChunking = AudioChunker(),
        client: any AudioTranscriptionClient = OpenAISDKTranscriptionClient(),
        fileSizer: any AudioFileSizing = LocalAudioFileSizer()
    ) {
        self.chunker = chunker
        self.client = client
        self.fileSizer = fileSizer
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
        let outputDirectory = FileManager.default.temporaryDirectory
            .appending(path: "WisperChunks-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let files = try await prepareTransportFiles(
            audioURL: audioURL,
            preferredChunkSeconds: chunkSeconds,
            outputDirectory: outputDirectory,
            progress: progress
        )
        guard files.isEmpty == false else {
            throw TranscriptionError.audioNormalizationUnsupported
        }

        if files.count == 1, files[0] == audioURL {
            await progress?(.transcriptionStart(label: audioURL.lastPathComponent))
            let text = try await transcribeSingleFile(audioURL: audioURL, apiKey: apiKey)
            await progress?(.transcriptionComplete(label: audioURL.lastPathComponent))
            guard text.isEmpty == false else { throw TranscriptionError.emptyResult }
            return TranscriptionResult(mode: .plain, text: text, requestCount: 1)
        }

        let chunkTexts = try await transcribeConcurrently(
            files,
            apiKey: apiKey,
            progress: progress
        )
        let stitchedText = chunkTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: "\n\n")
        guard stitchedText.isEmpty == false else { throw TranscriptionError.emptyResult }
        return TranscriptionResult(mode: .chunked, text: stitchedText, requestCount: files.count)
    }

    private func transcribeSingleFile(audioURL: URL, apiKey: String) async throws -> String {
        try await client.transcribe(audioURL: audioURL, apiKey: apiKey)
    }

    private func prepareTransportFiles(
        audioURL: URL,
        preferredChunkSeconds: Int?,
        outputDirectory: URL,
        progress: (@MainActor (TranscriptionProgress) -> Void)?
    ) async throws -> [URL] {
        let sourceSize = try fileSizer.size(of: audioURL)
        var initialFiles = [audioURL]
        var didChunk = false

        if let preferredChunkSeconds, preferredChunkSeconds > 0 {
            if let duration = try? await chunker.duration(of: audioURL),
               duration > TimeInterval(preferredChunkSeconds) {
                await progress?(.chunkingStart)
                initialFiles = try await chunker.split(
                    audioURL: audioURL,
                    chunkSeconds: preferredChunkSeconds,
                    outputDirectory: outputDirectory.appending(path: "preferred", directoryHint: .isDirectory)
                )
                didChunk = true
            }
        }

        if didChunk == false, sourceSize >= Self.maximumTransportBytes {
            let duration: TimeInterval
            do {
                duration = try await chunker.duration(of: audioURL)
            } catch {
                throw TranscriptionError.audioNormalizationUnsupported
            }
            let estimated = Int(
                floor(duration * (Double(Self.maximumTransportBytes - 1) / Double(sourceSize)) * 0.9)
            )
            guard estimated >= Self.minimumChunkSeconds else {
                throw TranscriptionError.audioTooLarge
            }
            await progress?(.chunkingStart)
            initialFiles = try await chunker.split(
                audioURL: audioURL,
                chunkSeconds: estimated,
                outputDirectory: outputDirectory.appending(path: "transport", directoryHint: .isDirectory)
            )
            didChunk = true
        }

        let safeFiles = try await enforceTransportCeiling(
            initialFiles,
            outputDirectory: outputDirectory,
            recursionDepth: 0
        )
        if didChunk || safeFiles != [audioURL] {
            await progress?(.chunkingComplete(total: safeFiles.count))
        }
        return safeFiles
    }

    private func enforceTransportCeiling(
        _ files: [URL],
        outputDirectory: URL,
        recursionDepth: Int
    ) async throws -> [URL] {
        guard recursionDepth < 20 else { throw TranscriptionError.audioTooLarge }
        var safeFiles: [URL] = []
        for (index, file) in files.enumerated() {
            let size = try fileSizer.size(of: file)
            if size < Self.maximumTransportBytes {
                safeFiles.append(file)
                continue
            }

            let duration: TimeInterval
            do {
                duration = try await chunker.duration(of: file)
            } catch {
                throw TranscriptionError.audioNormalizationUnsupported
            }
            let nextChunkSeconds = Int(floor(duration / 2))
            guard nextChunkSeconds >= Self.minimumChunkSeconds,
                  TimeInterval(nextChunkSeconds) < duration else {
                throw TranscriptionError.audioTooLarge
            }
            let splitFiles = try await chunker.split(
                audioURL: file,
                chunkSeconds: nextChunkSeconds,
                outputDirectory: outputDirectory.appending(
                    path: "retry-\(recursionDepth)-\(index)",
                    directoryHint: .isDirectory
                )
            )
            guard splitFiles.isEmpty == false, splitFiles != [file] else {
                throw TranscriptionError.audioTooLarge
            }
            safeFiles.append(contentsOf: try await enforceTransportCeiling(
                splitFiles,
                outputDirectory: outputDirectory,
                recursionDepth: recursionDepth + 1
            ))
        }
        return safeFiles
    }

    private func transcribeConcurrently(
        _ files: [URL],
        apiKey: String,
        progress: (@MainActor (TranscriptionProgress) -> Void)?
    ) async throws -> [String] {
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var nextIndex = 0
            var results = Array(repeating: "", count: files.count)

            func addTask(index: Int) {
                let file = files[index]
                group.addTask {
                    let label = "chunk \(index + 1)/\(files.count)"
                    await progress?(.transcriptionStart(label: label))
                    let text = try await client.transcribe(audioURL: file, apiKey: apiKey)
                    await progress?(.transcriptionComplete(label: label))
                    return (index, text)
                }
            }

            while nextIndex < min(Self.maximumConcurrentRequests, files.count) {
                addTask(index: nextIndex)
                nextIndex += 1
            }

            while let (index, text) = try await group.next() {
                results[index] = text
                await progress?(.chunkComplete(current: index + 1, total: files.count))
                if nextIndex < files.count {
                    addTask(index: nextIndex)
                    nextIndex += 1
                }
            }
            return results
        }
    }
}

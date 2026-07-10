import XCTest
@testable import Wisper

final class OpenAITranscriptionServiceTests: XCTestCase {
    func testLongVideoUsesChunksAndStitchesTextInOrder() async throws {
        let sourceURL = URL(filePath: "/tmp/lecture.mp4")
        let chunkURLs = [
            URL(filePath: "/tmp/chunk-001.m4a"),
            URL(filePath: "/tmp/chunk-002.m4a"),
            URL(filePath: "/tmp/chunk-003.m4a")
        ]
        let chunker = StubAudioChunker(durationSeconds: 7_200, chunkURLs: chunkURLs)
        let client = StubTranscriptionClient(transcripts: [
            "chunk-001.m4a": "Intro",
            "chunk-002.m4a": "Middle",
            "chunk-003.m4a": "Wrap"
        ])
        let service = OpenAITranscriptionService(chunker: chunker, client: client)

        let result = try await service.transcribe(
            audioURL: sourceURL,
            apiKey: "test-key",
            chunkSeconds: 1_800
        )

        XCTAssertEqual(result.mode, .chunked)
        XCTAssertEqual(result.text, "Intro\n\nMiddle\n\nWrap")
        let splitCallCount = await chunker.splitCallCount
        let lastChunkSeconds = await chunker.lastChunkSeconds
        let transcribedURLs = await client.transcribedURLs
        XCTAssertEqual(splitCallCount, 1)
        XCTAssertEqual(lastChunkSeconds, 1_800)
        XCTAssertEqual(transcribedURLs, chunkURLs)
    }

    func testShortVideoTranscribesOriginalFileWithoutChunking() async throws {
        let sourceURL = URL(filePath: "/tmp/clip.mp4")
        let chunker = StubAudioChunker(durationSeconds: 120, chunkURLs: [])
        let client = StubTranscriptionClient(transcripts: [
            "clip.mp4": "Short clip"
        ])
        let service = OpenAITranscriptionService(chunker: chunker, client: client)

        let result = try await service.transcribe(
            audioURL: sourceURL,
            apiKey: "test-key",
            chunkSeconds: 1_800
        )

        XCTAssertEqual(result.mode, .plain)
        XCTAssertEqual(result.text, "Short clip")
        let splitCallCount = await chunker.splitCallCount
        let transcribedURLs = await client.transcribedURLs
        XCTAssertEqual(splitCallCount, 0)
        XCTAssertEqual(transcribedURLs, [sourceURL])
    }
}

private actor StubAudioChunker: AudioChunking {
    private let durationSeconds: TimeInterval
    private let chunkURLs: [URL]
    private(set) var splitCallCount = 0
    private(set) var lastChunkSeconds: Int?

    init(durationSeconds: TimeInterval, chunkURLs: [URL]) {
        self.durationSeconds = durationSeconds
        self.chunkURLs = chunkURLs
    }

    func duration(of audioURL: URL) async throws -> TimeInterval {
        durationSeconds
    }

    func split(audioURL: URL, chunkSeconds: Int, outputDirectory: URL) async throws -> [URL] {
        splitCallCount += 1
        lastChunkSeconds = chunkSeconds
        return chunkURLs
    }
}

private actor StubTranscriptionClient: AudioTranscriptionClient {
    private let transcripts: [String: String]
    private(set) var transcribedURLs: [URL] = []

    init(transcripts: [String: String]) {
        self.transcripts = transcripts
    }

    func transcribe(audioURL: URL, apiKey: String) async throws -> String {
        transcribedURLs.append(audioURL)
        return transcripts[audioURL.lastPathComponent] ?? ""
    }
}

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
        let service = OpenAITranscriptionService(
            chunker: chunker,
            client: client,
            fileSizer: StubAudioFileSizer()
        )

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
        XCTAssertEqual(Set(transcribedURLs), Set(chunkURLs))
    }

    func testShortVideoTranscribesOriginalFileWithoutChunking() async throws {
        let sourceURL = URL(filePath: "/tmp/clip.mp4")
        let chunker = StubAudioChunker(durationSeconds: 120, chunkURLs: [])
        let client = StubTranscriptionClient(transcripts: [
            "clip.mp4": "Short clip"
        ])
        let service = OpenAITranscriptionService(
            chunker: chunker,
            client: client,
            fileSizer: StubAudioFileSizer()
        )

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

    func testFileAtTransportCeilingIsSplitBeforeAnyRequest() async throws {
        let sourceURL = URL(filePath: "/tmp/ceiling.mp4")
        let chunks = [
            URL(filePath: "/tmp/safe-1.m4a"),
            URL(filePath: "/tmp/safe-2.m4a")
        ]
        let chunker = StubAudioChunker(durationSeconds: 120, chunkURLs: chunks)
        let client = StubTranscriptionClient(transcripts: [
            "safe-1.m4a": "First",
            "safe-2.m4a": "Second"
        ])
        let service = OpenAITranscriptionService(
            chunker: chunker,
            client: client,
            fileSizer: StubAudioFileSizer(sizes: [
                sourceURL: OpenAITranscriptionService.maximumTransportBytes,
                chunks[0]: 1_000,
                chunks[1]: 1_000
            ])
        )

        let result = try await service.transcribe(audioURL: sourceURL, apiKey: "key", chunkSeconds: nil)

        XCTAssertEqual(result.text, "First\n\nSecond")
        let transcribedURLs = await client.transcribedURLs
        XCTAssertFalse(transcribedURLs.contains(sourceURL))
    }

    func testChunkRequestsNeverExceedTwoConcurrentCalls() async throws {
        let sourceURL = URL(filePath: "/tmp/long.mp4")
        let chunks = (1...5).map { URL(filePath: "/tmp/chunk-\($0).m4a") }
        let chunker = StubAudioChunker(durationSeconds: 600, chunkURLs: chunks)
        let client = ConcurrencyTrackingTranscriptionClient()
        let service = OpenAITranscriptionService(
            chunker: chunker,
            client: client,
            fileSizer: StubAudioFileSizer()
        )

        _ = try await service.transcribe(audioURL: sourceURL, apiKey: "key", chunkSeconds: 60)

        let maximumActiveCalls = await client.maximumActiveCalls
        XCTAssertEqual(maximumActiveCalls, 2)
    }

    func testOversizedGeneratedChunkIsRecursivelyBisected() async throws {
        let source = URL(filePath: "/tmp/source.m4a")
        let oversized = URL(filePath: "/tmp/oversized.m4a")
        let safeA = URL(filePath: "/tmp/safe-a.m4a")
        let safeB = URL(filePath: "/tmp/safe-b.m4a")
        let chunker = ScriptedAudioChunker(
            durations: [source: 120, oversized: 60],
            splits: [source: [oversized], oversized: [safeA, safeB]]
        )
        let client = StubTranscriptionClient(transcripts: [
            safeA.lastPathComponent: "First",
            safeB.lastPathComponent: "Second"
        ])
        let service = OpenAITranscriptionService(
            chunker: chunker,
            client: client,
            fileSizer: StubAudioFileSizer(sizes: [
                source: 1,
                oversized: OpenAITranscriptionService.maximumTransportBytes,
                safeA: 1,
                safeB: 1
            ])
        )

        let result = try await service.transcribe(audioURL: source, apiKey: "key", chunkSeconds: 60)

        XCTAssertEqual(result.text, "First\n\nSecond")
        let splitInputs = await chunker.splitInputs
        XCTAssertEqual(splitInputs, [source, oversized])
    }

    func testChunkFailureCancelsSiblingRequests() async throws {
        let source = URL(filePath: "/tmp/source.m4a")
        let fail = URL(filePath: "/tmp/fail.m4a")
        let slow = URL(filePath: "/tmp/slow.m4a")
        let client = FailingTranscriptionClient()
        let service = OpenAITranscriptionService(
            chunker: StubAudioChunker(durationSeconds: 120, chunkURLs: [fail, slow]),
            client: client,
            fileSizer: StubAudioFileSizer()
        )

        do {
            _ = try await service.transcribe(audioURL: source, apiKey: "key", chunkSeconds: 60)
            XCTFail("Expected a chunk request to fail")
        } catch {
            let cancelledCalls = await client.cancelledCalls
            XCTAssertEqual(cancelledCalls, 1)
        }
    }
}

private struct StubAudioFileSizer: AudioFileSizing {
    let sizes: [URL: Int64]

    init(sizes: [URL: Int64] = [:]) {
        self.sizes = sizes
    }

    func size(of url: URL) throws -> Int64 {
        sizes[url] ?? 1
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

private actor ScriptedAudioChunker: AudioChunking {
    let durations: [URL: TimeInterval]
    let splits: [URL: [URL]]
    private(set) var splitInputs: [URL] = []

    init(durations: [URL: TimeInterval], splits: [URL: [URL]]) {
        self.durations = durations
        self.splits = splits
    }

    func duration(of audioURL: URL) async throws -> TimeInterval {
        durations[audioURL] ?? 0
    }

    func split(audioURL: URL, chunkSeconds: Int, outputDirectory: URL) async throws -> [URL] {
        splitInputs.append(audioURL)
        return splits[audioURL] ?? []
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

private actor ConcurrencyTrackingTranscriptionClient: AudioTranscriptionClient {
    private(set) var activeCalls = 0
    private(set) var maximumActiveCalls = 0

    func transcribe(audioURL: URL, apiKey: String) async throws -> String {
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        do {
            try await Task.sleep(for: .milliseconds(20))
            activeCalls -= 1
            return audioURL.lastPathComponent
        } catch {
            activeCalls -= 1
            throw error
        }
    }
}

private enum StubTranscriptionError: Error {
    case failed
}

private actor FailingTranscriptionClient: AudioTranscriptionClient {
    private(set) var cancelledCalls = 0

    func transcribe(audioURL: URL, apiKey: String) async throws -> String {
        if audioURL.lastPathComponent == "fail.m4a" {
            try await Task.sleep(for: .milliseconds(20))
            throw StubTranscriptionError.failed
        }
        do {
            try await Task.sleep(for: .seconds(30))
            return "unexpected"
        } catch {
            cancelledCalls += 1
            throw error
        }
    }
}

import Foundation

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

struct OpenAITranscriptionService {
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
            let chunker = AudioChunker()
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

                var stitchedText = ""
                for (index, chunkURL) in chunks.enumerated() {
                    let label = "chunk \(index + 1)/\(chunks.count)"
                    await progress?(.transcriptionStart(label: label))
                    let text = try await transcribeSingleFile(audioURL: chunkURL, apiKey: apiKey)
                    await progress?(.transcriptionComplete(label: label))
                    stitchedText += "\n\n[\(chunkURL.lastPathComponent)]\n\n\(text)\n"
                    await progress?(.chunkComplete(current: index + 1, total: chunks.count))
                }

                return TranscriptionResult(mode: .chunked, text: stitchedText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        await progress?(.transcriptionStart(label: audioURL.lastPathComponent))
        let text = try await transcribeSingleFile(audioURL: audioURL, apiKey: apiKey)
        await progress?(.transcriptionComplete(label: audioURL.lastPathComponent))
        return TranscriptionResult(mode: .plain, text: text)
    }

    private func transcribeSingleFile(audioURL: URL, apiKey: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        let boundary = "Boundary-\(UUID().uuidString)"

        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try makeBody(audioURL: audioURL, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw TranscriptionError.requestFailed(message)
        }

        let decoded = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeBody(audioURL: URL, boundary: String) throws -> Data {
        var body = Data()
        let filename = audioURL.lastPathComponent
        let audioData = try Data(contentsOf: audioURL)

        body.appendFormField(name: "model", value: "gpt-4o-transcribe", boundary: boundary)
        body.appendFileField(
            name: "file",
            filename: filename,
            mimeType: mimeType(for: audioURL),
            data: audioData,
            boundary: boundary
        )
        body.appendString("--\(boundary)--\r\n")
        return body
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4":
            "audio/mp4"
        case "mp3":
            "audio/mpeg"
        case "wav":
            "audio/wav"
        default:
            "application/octet-stream"
        }
    }
}

private struct OpenAITranscriptionResponse: Decodable {
    let text: String
}

enum TranscriptionError: LocalizedError {
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "OpenAI returned an invalid response."
        case .requestFailed(let message):
            "OpenAI transcription failed: \(message)"
        }
    }
}

private extension Data {
    mutating func appendString(_ value: String) {
        append(Data(value.utf8))
    }

    mutating func appendFormField(name: String, value: String, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendFileField(name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        append(data)
        appendString("\r\n")
    }
}

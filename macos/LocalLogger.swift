import Foundation
import os

enum LocalLogLevel: String, Codable, Sendable {
    case info
    case warning
    case error
}

struct LocalLogger: Sendable {
    static let shared = LocalLogger()

    private let osLogger = Logger(subsystem: "com.wisper.mac", category: "local")
    private let queue = DispatchQueue(label: "com.wisper.mac.local-log")
    private let maxLogSizeBytes = 1_000_000

    var logFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Wisper/Logs/wisper.log", directoryHint: .notDirectory)
    }

    func info(_ message: String, metadata: [String: String] = [:]) {
        log(.info, message, metadata: metadata)
    }

    func warning(_ message: String, metadata: [String: String] = [:], error: Error? = nil) {
        log(.warning, message, metadata: metadata, error: error)
    }

    func error(_ message: String, metadata: [String: String] = [:], error: Error? = nil) {
        log(.error, message, metadata: metadata, error: error)
    }

    func log(_ level: LocalLogLevel, _ message: String, metadata: [String: String] = [:], error: Error? = nil) {
        let entry = LocalLogEntry(
            timestamp: Date(),
            level: level,
            message: message,
            metadata: metadata,
            errorDescription: error?.localizedDescription
        )

        write(entry)

        switch level {
        case .info:
            osLogger.info("\(message, privacy: .public)")
        case .warning:
            osLogger.warning("\(message, privacy: .public)")
        case .error:
            osLogger.error("\(message, privacy: .public)")
        }
    }

    private func write(_ entry: LocalLogEntry) {
        do {
            let data = try JSONEncoder.wisper.encode(entry)
            guard var line = String(data: data, encoding: .utf8) else {
                osLogger.error("Could not encode local log line as UTF-8")
                return
            }
            line.append("\n")
            let lineData = Data(line.utf8)
            let fileURL = logFileURL
            let directory = fileURL.deletingLastPathComponent()

            queue.async {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try Self.rotateLogIfNeeded(fileURL: fileURL, maxLogSizeBytes: maxLogSizeBytes)

                    if FileManager.default.fileExists(atPath: fileURL.path) == false {
                        _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                    }

                    let fileHandle = try FileHandle(forWritingTo: fileURL)
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(lineData)
                    fileHandle.closeFile()
                } catch {
                    osLogger.error("Could not write local log: \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            osLogger.error("Could not encode local log entry: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func rotateLogIfNeeded(fileURL: URL, maxLogSizeBytes: Int) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = attributes[.size] as? NSNumber
        guard size?.intValue ?? 0 > maxLogSizeBytes else { return }

        let rotatedURL = fileURL.deletingLastPathComponent().appending(path: "wisper.previous.log")
        if FileManager.default.fileExists(atPath: rotatedURL.path) {
            try FileManager.default.removeItem(at: rotatedURL)
        }
        try FileManager.default.moveItem(at: fileURL, to: rotatedURL)
    }
}

private struct LocalLogEntry: Codable, Sendable {
    let timestamp: Date
    let level: LocalLogLevel
    let message: String
    let metadata: [String: String]
    let errorDescription: String?
}

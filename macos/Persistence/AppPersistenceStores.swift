import Foundation

protocol AppSettingsStoring {
    func load() throws -> AppSettings
    func save(_ settings: AppSettings) throws
}

protocol TranscriptHistoryStoring {
    func load() throws -> [Transcript]
    func save(_ history: [Transcript]) throws
}

enum AppStorageLocation {
    static let supportDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Wisper", directoryHint: .isDirectory)

    static let settingsURL = supportDirectory.appending(path: "settings.json")
    static let historyURL = supportDirectory.appending(path: "history.json")
}

struct JSONAppSettingsStore: AppSettingsStoring {
    private let settingsURL: URL

    init(settingsURL: URL = AppStorageLocation.settingsURL) {
        self.settingsURL = settingsURL
    }

    func load() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return .default
        }

        let data = try Data(contentsOf: settingsURL)
        if let legacyShortcut = try? JSONDecoder.wisper.decode(KeyboardShortcut.self, from: data) {
            var settings = AppSettings.default
            settings.shortcut = legacyShortcut
            return settings
        }

        return try JSONDecoder.wisper.decode(AppSettings.self, from: data)
    }

    func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.wisper.encode(settings)
        try data.write(to: settingsURL, options: .atomic)
    }
}

struct JSONTranscriptHistoryStore: TranscriptHistoryStoring {
    private let historyURL: URL

    init(historyURL: URL = AppStorageLocation.historyURL) {
        self.historyURL = historyURL
    }

    func load() throws -> [Transcript] {
        guard FileManager.default.fileExists(atPath: historyURL.path) else {
            return []
        }

        let data = try Data(contentsOf: historyURL)
        return try JSONDecoder.wisper.decode([Transcript].self, from: data)
    }

    func save(_ history: [Transcript]) throws {
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.wisper.encode(history)
        try data.write(to: historyURL, options: .atomic)
    }
}

extension JSONDecoder {
    static var wisper: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var wisper: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

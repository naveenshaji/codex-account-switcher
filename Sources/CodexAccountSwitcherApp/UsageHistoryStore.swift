import Foundation

enum UsageHistoryStoreError: Error {
    case homeDirectoryUnavailable
}

struct UsageHistoryStore {
    private let fileManager = FileManager.default

    func load() throws -> UsageHistoryEnvelope {
        let fileURL = try historyFileURL()
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return UsageHistoryEnvelope(pointsByProfileID: [:])
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UsageHistoryEnvelope.self, from: data)
    }

    func save(_ envelope: UsageHistoryEnvelope) throws {
        let fileURL = try historyFileURL()
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)

        let tempURL = directory.appendingPathComponent("usage-history.json.tmp", isDirectory: false)
        try data.write(to: tempURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)

        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        try fileManager.moveItem(at: tempURL, to: fileURL)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func historyFileURL() throws -> URL {
        guard let home = fileManager.homeDirectoryForCurrentUser as URL? else {
            throw UsageHistoryStoreError.homeDirectoryUnavailable
        }

        return home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("account-switcher", isDirectory: true)
            .appendingPathComponent("usage-history.json", isDirectory: false)
    }
}

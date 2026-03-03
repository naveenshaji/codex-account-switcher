import Foundation
import Security

enum LegacyKeychainError: Error {
    case unexpectedStatus(OSStatus)
}

enum ProfilesStoreError: Error {
    case homeDirectoryUnavailable
}

private struct LegacyKeychainStore {
    let service: String

    init(service: String = "com.naveenshaji.codex-account-switcher") {
        self.service = service
    }

    func readData(account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw LegacyKeychainError.unexpectedStatus(status)
        }

        return result as? Data
    }

    func delete(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LegacyKeychainError.unexpectedStatus(status)
        }
    }
}

struct ProfilesStore {
    private let fileManager = FileManager.default
    private let legacyKeychain = LegacyKeychainStore()
    private let legacyAccount = "profiles-v1"

    func load() throws -> ProfilesEnvelope {
        let profilesURL = try profilesFileURL()
        if fileManager.fileExists(atPath: profilesURL.path) {
            return try decodeEnvelope(from: profilesURL)
        }

        // One-time migration path from old keychain-backed store.
        if let legacyEnvelope = try loadFromLegacyKeychainIfAvailable() {
            try saveToDisk(legacyEnvelope, at: profilesURL)
            try? legacyKeychain.delete(account: legacyAccount)
            return legacyEnvelope
        }

        return ProfilesEnvelope(profiles: [], activeProfileID: nil)
    }

    func save(_ envelope: ProfilesEnvelope) throws {
        let profilesURL = try profilesFileURL()
        try saveToDisk(envelope, at: profilesURL)
    }

    private func loadFromLegacyKeychainIfAvailable() throws -> ProfilesEnvelope? {
        guard let data = try? legacyKeychain.readData(account: legacyAccount) else {
            return nil
        }
        return try decodeEnvelope(from: data)
    }

    private func profilesFileURL() throws -> URL {
        guard let home = fileManager.homeDirectoryForCurrentUser as URL? else {
            throw ProfilesStoreError.homeDirectoryUnavailable
        }

        return home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("account-switcher", isDirectory: true)
            .appendingPathComponent("profiles.json", isDirectory: false)
    }

    private func decodeEnvelope(from fileURL: URL) throws -> ProfilesEnvelope {
        let data = try Data(contentsOf: fileURL)
        return try decodeEnvelope(from: data)
    }

    private func decodeEnvelope(from data: Data) throws -> ProfilesEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProfilesEnvelope.self, from: data)
    }

    private func saveToDisk(_ envelope: ProfilesEnvelope, at fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)

        let tempURL = directory.appendingPathComponent("profiles.json.tmp", isDirectory: false)
        try data.write(to: tempURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)

        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        try fileManager.moveItem(at: tempURL, to: fileURL)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

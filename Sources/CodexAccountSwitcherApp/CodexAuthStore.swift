import Foundation

enum CodexAuthStoreError: Error {
    case homeDirectoryUnavailable
    case parseFailed
}

struct CodexAuthStore {
    struct AuthJSON: Codable {
        struct TokenBag: Codable {
            var idToken: String
            var accessToken: String
            var refreshToken: String
            var accountID: String

            enum CodingKeys: String, CodingKey {
                case idToken = "id_token"
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case accountID = "account_id"
            }
        }

        var authMode: String
        var openAIAPIKey: String?
        var tokens: TokenBag
        var lastRefresh: String

        enum CodingKeys: String, CodingKey {
            case authMode = "auth_mode"
            case openAIAPIKey = "OPENAI_API_KEY"
            case tokens
            case lastRefresh = "last_refresh"
        }
    }

    private let fileManager = FileManager.default

    func authFilePath() throws -> URL {
        guard let home = fileManager.homeDirectoryForCurrentUser as URL? else {
            throw CodexAuthStoreError.homeDirectoryUnavailable
        }
        return home.appendingPathComponent(".codex/auth.json", isDirectory: false)
    }

    func activate(profile: CodexAuthProfile) throws {
        let authPath = try authFilePath()
        try write(profile: profile, toAuthFileURL: authPath)
    }

    func write(profile: CodexAuthProfile, toAuthFileURL authPath: URL) throws {
        let auth = AuthJSON(
            authMode: "chatgpt",
            openAIAPIKey: nil,
            tokens: .init(
                idToken: profile.idToken ?? "",
                accessToken: profile.accessToken,
                refreshToken: profile.refreshToken ?? "",
                accountID: profile.accountID
            ),
            lastRefresh: ISO8601DateFormatter().string(from: Date())
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(auth)

        let codexDir = authPath.deletingLastPathComponent()
        try fileManager.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let tempPath = codexDir.appendingPathComponent("auth.json.tmp", isDirectory: false)
        try data.write(to: tempPath, options: .atomic)

        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempPath.path)

        if fileManager.fileExists(atPath: authPath.path) {
            try fileManager.removeItem(at: authPath)
        }
        try fileManager.moveItem(at: tempPath, to: authPath)
    }

    func importCurrentProfile() throws -> CodexAuthProfile {
        let path = try authFilePath()
        return try importProfile(fromAuthFileURL: path)
    }

    func importProfile(fromAuthFileURL path: URL) throws -> CodexAuthProfile {
        let data = try Data(contentsOf: path)

        let decoder = JSONDecoder()
        let auth = try decoder.decode(AuthJSON.self, from: data)

        let jwtMeta = JWTMetadataParser.parse(idToken: auth.tokens.idToken)
        let accountID = jwtMeta.accountID ?? auth.tokens.accountID

        return CodexAuthProfile(
            name: jwtMeta.email ?? "Imported Account",
            email: jwtMeta.email,
            planType: jwtMeta.planType,
            accountID: accountID,
            accessToken: auth.tokens.accessToken,
            refreshToken: auth.tokens.refreshToken,
            idToken: auth.tokens.idToken
        )
    }
}

private struct JWTMetadataParser {
    struct JWTInfo {
        var email: String?
        var planType: String?
        var accountID: String?
    }

    static func parse(idToken: String) -> JWTInfo {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else {
            return JWTInfo()
        }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = payload.count % 4
        if padding > 0 {
            payload += String(repeating: "=", count: 4 - padding)
        }

        guard let payloadData = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return JWTInfo()
        }

        var info = JWTInfo()
        info.email = object["email"] as? String

        if let authNode = object["https://api.openai.com/auth"] as? [String: Any] {
            info.planType = authNode["chatgpt_plan_type"] as? String
            info.accountID = authNode["chatgpt_account_id"] as? String
        }

        return info
    }
}

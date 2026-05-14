import AppKit
import Foundation

enum CodexOAuthError: LocalizedError {
    case startFailed
    case codexBinaryNotFound
    case appServerExited(status: Int32, details: String?)
    case accountRefreshFailed(String)
    case loginStartFailed(String)
    case invalidLoginResponse
    case failedToOpenAuthURL
    case loginCanceled(String)
    case authFileMissing
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .startFailed:
            return "Failed to start codex app-server process."
        case .codexBinaryNotFound:
            return "Could not find the codex CLI binary. Install codex and make sure it is available at a standard path."
        case .appServerExited(let status, let details):
            if let details, !details.isEmpty {
                return "Codex app-server exited with status \(status): \(details)"
            }
            return "Codex app-server exited with status \(status)."
        case .accountRefreshFailed(let message):
            return "Token refresh failed: \(message)"
        case .loginStartFailed(let message):
            return "Failed to start ChatGPT login: \(message)"
        case .invalidLoginResponse:
            return "Unexpected login response from codex app-server."
        case .failedToOpenAuthURL:
            return "Unable to open OAuth URL in browser."
        case .loginCanceled(let message):
            return "Login did not complete: \(message)"
        case .authFileMissing:
            return "OAuth completed but no auth file was produced."
        case .timedOut(let stage):
            return "Timed out while waiting for \(stage)."
        }
    }
}

struct CodexOAuthService {
    private let fileManager = FileManager.default
    private let authStore = CodexAuthStore()

    func addProfileViaChatGPTLogin() async throws -> CodexAuthProfile {
        let codexHome = try makeTempCodexHome()
        defer {
            try? fileManager.removeItem(at: codexHome)
        }

        let process = Process()
        let codexExecutable = try resolveCodexExecutable()
        process.executableURL = codexExecutable.url
        process.arguments = [
            "app-server",
            "-c",
            "cli_auth_credentials_store=\"file\""
        ]

        process.environment = resolvedEnvironment(codexHome: codexHome, codexExecutable: codexExecutable)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw CodexOAuthError.startFailed
        }

        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let rpc = JSONRPCSession(
            stdin: stdinPipe.fileHandleForWriting,
            stdout: stdoutPipe.fileHandleForReading
        )

        do {
            try await initialize(session: rpc)

            let login = try await startLogin(session: rpc)

            guard let authURL = URL(string: login.authURL), await MainActor.run(body: {
                NSWorkspace.shared.open(authURL)
            }) else {
                throw CodexOAuthError.failedToOpenAuthURL
            }

            try await waitForLoginCompletion(session: rpc, expectedLoginID: login.loginID)
        } catch {
            if let imported = await recoverImportedProfile(from: codexHome, timeoutSeconds: 10) {
                return imported
            }
            throw buildDetailedError(from: error, process: process, stderrPipe: stderrPipe)
        }

        if let imported = await recoverImportedProfile(from: codexHome, timeoutSeconds: 8) {
            return imported
        }

        throw CodexOAuthError.authFileMissing
    }

    func refreshProfileTokens(_ profile: CodexAuthProfile) async throws -> CodexAuthProfile {
        let codexHome = try makeTempCodexHome()
        defer {
            try? fileManager.removeItem(at: codexHome)
        }

        try authStore.write(
            profile: profile,
            toAuthFileURL: codexHome.appendingPathComponent("auth.json", isDirectory: false)
        )

        let process = Process()
        let codexExecutable = try resolveCodexExecutable()
        process.executableURL = codexExecutable.url
        process.arguments = [
            "app-server",
            "-c",
            "cli_auth_credentials_store=\"file\""
        ]
        process.environment = resolvedEnvironment(codexHome: codexHome, codexExecutable: codexExecutable)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw CodexOAuthError.startFailed
        }

        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let rpc = JSONRPCSession(
            stdin: stdinPipe.fileHandleForWriting,
            stdout: stdoutPipe.fileHandleForReading
        )

        do {
            try await initialize(session: rpc)
            let requestID = 2
            try await rpc.sendRequest(id: requestID, method: "account/read", params: [
                "refreshToken": true
            ])
            let response = try await rpc.waitForResponse(id: requestID, timeoutSeconds: 20)

            if let errorMessage = extractErrorMessage(from: response) {
                throw CodexOAuthError.accountRefreshFailed(errorMessage)
            }
        } catch {
            if let imported = await recoverImportedProfile(from: codexHome, timeoutSeconds: 5) {
                return imported
            }
            throw buildDetailedError(from: error, process: process, stderrPipe: stderrPipe)
        }

        if let imported = await recoverImportedProfile(from: codexHome, timeoutSeconds: 5) {
            return imported
        }

        throw CodexOAuthError.authFileMissing
    }

    private func makeTempCodexHome() throws -> URL {
        let base = fileManager.temporaryDirectory
        let path = base.appendingPathComponent("codex-oauth-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    private func resolveCodexExecutable() throws -> CodexExecutable {
        for candidate in codexExecutableCandidates() {
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return CodexExecutable(url: candidate)
            }
        }

        if let shellResolvedPath = resolveCodexPathViaLoginShell(),
           fileManager.isExecutableFile(atPath: shellResolvedPath.path) {
            return CodexExecutable(url: shellResolvedPath)
        }

        throw CodexOAuthError.codexBinaryNotFound
    }

    private func codexExecutableCandidates() -> [URL] {
        var candidates: [URL] = []

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for component in path.split(separator: ":") where !component.isEmpty {
                candidates.append(URL(fileURLWithPath: String(component)).appendingPathComponent("codex"))
            }
        }

        let commonPaths = [
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            NSHomeDirectory() + "/.local/bin/codex"
        ]

        for path in commonPaths {
            candidates.append(URL(fileURLWithPath: path))
        }

        candidates.append(contentsOf: nvmCodexExecutableCandidates())

        var deduped: [URL] = []
        var seen = Set<String>()
        for candidate in candidates {
            let path = candidate.path
            if seen.insert(path).inserted {
                deduped.append(candidate)
            }
        }
        return deduped
    }

    private func nvmCodexExecutableCandidates() -> [URL] {
        nvmDirectories().flatMap { nvmDirectory in
            let versionsDirectory = nvmDirectory.appendingPathComponent("versions/node", isDirectory: true)
            let defaultCandidates = defaultNVMNodeVersionCandidates(in: nvmDirectory, versionsDirectory: versionsDirectory)
            let installedCandidates = installedNVMNodeVersionDirectories(in: versionsDirectory)

            return dedupeURLs(defaultCandidates + installedCandidates).map {
                $0.appendingPathComponent("bin/codex", isDirectory: false)
            }
        }
    }

    private func nvmDirectories() -> [URL] {
        var directories: [URL] = []

        if let nvmDir = ProcessInfo.processInfo.environment["NVM_DIR"]?.trimmedNilIfEmpty {
            directories.append(URL(fileURLWithPath: nvmDir, isDirectory: true))
        }

        directories.append(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".nvm", isDirectory: true))

        return dedupeURLs(directories)
    }

    private func defaultNVMNodeVersionCandidates(in nvmDirectory: URL, versionsDirectory: URL) -> [URL] {
        guard let defaultVersion = readNVMAlias("default", in: nvmDirectory) else {
            return []
        }

        return nvmNodeVersionCandidates(
            matching: defaultVersion,
            in: nvmDirectory,
            versionsDirectory: versionsDirectory,
            visitedAliases: ["default"]
        )
    }

    private func nvmNodeVersionCandidates(
        matching specifier: String,
        in nvmDirectory: URL,
        versionsDirectory: URL,
        visitedAliases: Set<String>
    ) -> [URL] {
        if specifier == "node" || specifier.hasPrefix("stable") {
            return Array(installedNVMNodeVersionDirectories(in: versionsDirectory).prefix(1))
        }

        if specifier.hasPrefix("v") {
            return [versionsDirectory.appendingPathComponent(specifier, isDirectory: true)]
        }

        if specifier.first?.isNumber == true {
            return Array(installedNVMNodeVersionDirectories(in: versionsDirectory).filter { url in
                let version = String(url.lastPathComponent.dropFirst())
                return version == specifier || version.hasPrefix("\(specifier).")
            }.prefix(1))
        }

        if !visitedAliases.contains(specifier),
           let aliasValue = readNVMAlias(specifier, in: nvmDirectory) {
            var nextVisitedAliases = visitedAliases
            nextVisitedAliases.insert(specifier)
            let resolved = nvmNodeVersionCandidates(
                matching: aliasValue,
                in: nvmDirectory,
                versionsDirectory: versionsDirectory,
                visitedAliases: nextVisitedAliases
            )
            if !resolved.isEmpty {
                return resolved
            }
        }

        return []
    }

    private func readNVMAlias(_ alias: String, in nvmDirectory: URL) -> String? {
        let aliasURL = nvmDirectory.appendingPathComponent("alias", isDirectory: true)
            .appendingPathComponent(alias, isDirectory: false)

        guard let rawValue = try? String(contentsOf: aliasURL, encoding: .utf8),
              let value = rawValue.split(whereSeparator: \.isWhitespace).first else {
            return nil
        }

        return String(value)
    }

    private func installedNVMNodeVersionDirectories(in versionsDirectory: URL) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: versionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { url in
                guard url.lastPathComponent.hasPrefix("v") else {
                    return false
                }

                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            .sorted { lhs, rhs in
                compareNodeVersions(lhs.lastPathComponent, rhs.lastPathComponent) == .orderedDescending
            }
    }

    private func resolveCodexPathViaLoginShell() -> URL? {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"]?.trimmedNilIfEmpty ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lc", "command -v codex"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmedNilIfEmpty else {
            return nil
        }

        return URL(fileURLWithPath: output)
    }

    private func resolveLaunchPath() -> String? {
        let currentPath = ProcessInfo.processInfo.environment["PATH"]?.trimmedNilIfEmpty
        let shellPath = ProcessInfo.processInfo.environment["SHELL"]?.trimmedNilIfEmpty ?? "/bin/zsh"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lc", "printenv PATH"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return currentPath
        }

        guard process.terminationStatus == 0 else {
            return currentPath
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let shellResolvedPath = String(data: data, encoding: .utf8)?.trimmedNilIfEmpty

        return shellResolvedPath ?? currentPath
    }

    private func resolvedEnvironment(codexHome: URL, codexExecutable: CodexExecutable) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = codexHome.path
        env["PATH"] = mergedPath(
            prepending: [codexExecutable.binDirectory],
            basePath: resolveLaunchPath()
        )
        return env
    }

    private func initialize(session: JSONRPCSession) async throws {
        let initializeRequest: [String: Any] = [
            "clientInfo": [
                "name": "codex-account-switcher",
                "version": "0.1.1"
            ],
            "capabilities": [
                "experimentalApi": true
            ]
        ]

        let initializeID = 1
        try await session.sendRequest(id: initializeID, method: "initialize", params: initializeRequest)
        _ = try await session.waitForResponse(id: initializeID, timeoutSeconds: 20)
        try await session.sendNotification(method: "initialized", params: nil)
    }

    private func startLogin(session: JSONRPCSession) async throws -> (loginID: String, authURL: String) {
        let loginID = 2
        try await session.sendRequest(id: loginID, method: "account/login/start", params: ["type": "chatgpt"])
        let response = try await session.waitForResponse(id: loginID, timeoutSeconds: 20)

        if let error = response["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "unknown error"
            throw CodexOAuthError.loginStartFailed(message)
        }

        guard let result = response["result"] as? [String: Any],
              let type = result["type"] as? String,
              type == "chatgpt",
              let flowID = result["loginId"] as? String,
              let authURL = result["authUrl"] as? String else {
            throw CodexOAuthError.invalidLoginResponse
        }

        return (flowID, authURL)
    }

    private func extractErrorMessage(from response: [String: Any]) -> String? {
        guard let error = response["error"] as? [String: Any] else {
            return nil
        }

        if let message = error["message"] as? String,
           let trimmed = message.trimmedNilIfEmpty {
            return trimmed
        }

        if let code = error["code"] {
            return "app-server request failed (\(code))"
        }

        return "unknown app-server error"
    }

    private func waitForLoginCompletion(session: JSONRPCSession, expectedLoginID: String) async throws {
        let deadline = Date().addingTimeInterval(300)

        while Date() < deadline {
            let message = try await session.readMessage(timeoutSeconds: 30)
            guard let method = message["method"] as? String,
                  method == "account/login/completed",
                  let params = message["params"] as? [String: Any] else {
                continue
            }

            let loginID = params["loginId"] as? String
            if let loginID, loginID != expectedLoginID {
                continue
            }

            let success = (params["success"] as? Bool) ?? false
            if success {
                return
            }

            let error = (params["error"] as? String) ?? "unknown reason"
            throw CodexOAuthError.loginCanceled(error)
        }

        throw CodexOAuthError.timedOut("OAuth completion")
    }

    private func waitForAuthFile(at path: URL, timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if fileManager.fileExists(atPath: path.path) {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return fileManager.fileExists(atPath: path.path)
    }

    private func recoverImportedProfile(from codexHome: URL, timeoutSeconds: TimeInterval) async -> CodexAuthProfile? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        repeat {
            for candidate in candidateAuthFilePaths(in: codexHome) {
                if let imported = try? CodexAuthStore().importProfile(fromAuthFileURL: candidate) {
                    return imported
                }
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        } while Date() < deadline

        for candidate in candidateAuthFilePaths(in: codexHome) {
            if let imported = try? CodexAuthStore().importProfile(fromAuthFileURL: candidate) {
                return imported
            }
        }

        return nil
    }

    private func candidateAuthFilePaths(in codexHome: URL) -> [URL] {
        var candidates: [URL] = [
            codexHome.appendingPathComponent("auth.json", isDirectory: false),
            codexHome.appendingPathComponent(".codex/auth.json", isDirectory: false)
        ]

        if let enumerator = fileManager.enumerator(
            at: codexHome,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard fileURL.lastPathComponent == "auth.json" else { continue }
                candidates.append(fileURL)
            }
        }

        var deduped: [URL] = []
        var seen = Set<String>()
        for candidate in candidates {
            let path = candidate.path
            if seen.insert(path).inserted, fileManager.fileExists(atPath: path) {
                deduped.append(candidate)
            }
        }
        return deduped
    }

    private func buildDetailedError(from error: Error, process: Process, stderrPipe: Pipe) -> Error {
        guard !process.isRunning else {
            return error
        }

        process.waitUntilExit()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmedNilIfEmpty

        if let oauthError = error as? CodexOAuthError {
            switch oauthError {
            case .loginCanceled(let message) where message.localizedCaseInsensitiveContains("closed unexpectedly"):
                return CodexOAuthError.appServerExited(status: process.terminationStatus, details: stderrText)
            case .invalidLoginResponse:
                return CodexOAuthError.appServerExited(status: process.terminationStatus, details: stderrText ?? "invalid login response")
            default:
                return error
            }
        }

        if let stderrText {
            return CodexOAuthError.appServerExited(status: process.terminationStatus, details: stderrText)
        }

        return error
    }

    private func mergedPath(prepending directories: [URL], basePath: String?) -> String {
        var components = directories.map(\.path)

        if let basePath {
            components.append(contentsOf: basePath.split(separator: ":").map(String.init))
        }

        var deduped: [String] = []
        var seen = Set<String>()
        for component in components where !component.isEmpty {
            if seen.insert(component).inserted {
                deduped.append(component)
            }
        }

        return deduped.joined(separator: ":")
    }

    private func dedupeURLs(_ urls: [URL]) -> [URL] {
        var deduped: [URL] = []
        var seen = Set<String>()
        for url in urls {
            if seen.insert(url.standardizedFileURL.path).inserted {
                deduped.append(url)
            }
        }
        return deduped
    }

    private func compareNodeVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = nodeVersionParts(lhs)
        let rhsParts = nodeVersionParts(rhs)
        let maxCount = max(lhsParts.count, rhsParts.count)

        for index in 0..<maxCount {
            let lhsPart = index < lhsParts.count ? lhsParts[index] : 0
            let rhsPart = index < rhsParts.count ? rhsParts[index] : 0

            if lhsPart > rhsPart {
                return .orderedDescending
            }

            if lhsPart < rhsPart {
                return .orderedAscending
            }
        }

        return .orderedSame
    }

    private func nodeVersionParts(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }
}

private struct CodexExecutable {
    let url: URL

    var binDirectory: URL {
        url.deletingLastPathComponent()
    }
}

private final class JSONRPCSession {
    private let stdin: FileHandle
    private let lineReader: AsyncByteLineReader

    init(stdin: FileHandle, stdout: FileHandle) {
        self.stdin = stdin
        self.lineReader = AsyncByteLineReader(stdout: stdout)
    }

    func sendRequest(id: Int, method: String, params: [String: Any]?) async throws {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method
        ]
        if let params {
            payload["params"] = params
        }
        try send(payload)
    }

    func sendNotification(method: String, params: [String: Any]?) async throws {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if let params {
            payload["params"] = params
        }
        try send(payload)
    }

    func waitForResponse(id: Int, timeoutSeconds: TimeInterval) async throws -> [String: Any] {
        while true {
            let message = try await readMessage(timeoutSeconds: timeoutSeconds)
            guard let responseID = message["id"] else {
                continue
            }

            if let intID = (responseID as? NSNumber)?.intValue, intID == id {
                return message
            }

            if let stringID = responseID as? String, stringID == String(id) {
                return message
            }
        }
    }

    func readMessage(timeoutSeconds: TimeInterval) async throws -> [String: Any] {
        _ = timeoutSeconds
        let line = try await lineReader.nextLine()

        guard let line else {
            throw CodexOAuthError.loginCanceled("app-server closed unexpectedly")
        }

        guard let data = line.data(using: String.Encoding.utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexOAuthError.loginCanceled("received invalid JSON from app-server")
        }

        return json
    }

    private func send(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        var line = data
        line.append(0x0A)
        try stdin.write(contentsOf: line)
    }

}

private final class AsyncByteLineReader {
    private var iterator: FileHandle.AsyncBytes.Iterator
    private var bufferedLine = Data()

    init(stdout: FileHandle) {
        self.iterator = stdout.bytes.makeAsyncIterator()
    }

    func nextLine() async throws -> String? {
        while let byte = try await iterator.next() {
            if byte == 0x0A {
                let line = String(data: bufferedLine, encoding: .utf8)
                bufferedLine.removeAll(keepingCapacity: true)
                return line
            }
            bufferedLine.append(byte)
        }

        if bufferedLine.isEmpty {
            return nil
        }
        let line = String(data: bufferedLine, encoding: .utf8)
        bufferedLine.removeAll(keepingCapacity: false)
        return line
    }
}

import AppKit
import Foundation

enum CodexOAuthError: LocalizedError {
    case startFailed
    case codexBinaryNotFound
    case appServerExited(status: Int32, details: String?)
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

    func addProfileViaChatGPTLogin() async throws -> CodexAuthProfile {
        let codexHome = try makeTempCodexHome()
        defer {
            try? fileManager.removeItem(at: codexHome)
        }

        let process = Process()
        process.executableURL = try resolveCodexExecutableURL()
        process.arguments = [
            "app-server",
            "-c",
            "cli_auth_credentials_store=\"file\""
        ]

        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = codexHome.path
        if let resolvedPath = resolveLaunchPath() {
            env["PATH"] = resolvedPath
        }
        process.environment = env

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

    private func makeTempCodexHome() throws -> URL {
        let base = fileManager.temporaryDirectory
        let path = base.appendingPathComponent("codex-oauth-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    private func resolveCodexExecutableURL() throws -> URL {
        for candidate in codexExecutableCandidates() {
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        if let shellResolvedPath = resolveCodexPathViaLoginShell(),
           fileManager.isExecutableFile(atPath: shellResolvedPath.path) {
            return shellResolvedPath
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

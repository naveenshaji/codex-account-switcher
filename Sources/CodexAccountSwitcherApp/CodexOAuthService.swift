import AppKit
import Foundation

enum CodexOAuthError: LocalizedError {
    case startFailed
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
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "codex",
            "app-server",
            "-c",
            "cli_auth_credentials_store=\"file\""
        ]

        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = codexHome.path
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

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

        try await initialize(session: rpc)

        let login = try await startLogin(session: rpc)

        guard let authURL = URL(string: login.authURL), await MainActor.run(body: {
            NSWorkspace.shared.open(authURL)
        }) else {
            throw CodexOAuthError.failedToOpenAuthURL
        }

        try await waitForLoginCompletion(session: rpc, expectedLoginID: login.loginID)

        let authPath = codexHome.appendingPathComponent("auth.json", isDirectory: false)
        guard fileManager.fileExists(atPath: authPath.path) else {
            throw CodexOAuthError.authFileMissing
        }

        return try CodexAuthStore().importProfile(fromAuthFileURL: authPath)
    }

    private func makeTempCodexHome() throws -> URL {
        let base = fileManager.temporaryDirectory
        let path = base.appendingPathComponent("codex-oauth-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    private func initialize(session: JSONRPCSession) async throws {
        let initializeRequest: [String: Any] = [
            "clientInfo": [
                "name": "codex-account-switcher",
                "version": "0.1.0"
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

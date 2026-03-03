import AppKit
import Foundation

enum ProcessActions {
    static func isCodexDesktopRunning() -> Bool {
        let knownBundleIDs: Set<String> = [
            "com.openai.codex",
            "com.openai.chatgpt.codex",
            "com.openai.chatgpt"
        ]

        return NSWorkspace.shared.runningApplications.contains { app in
            if let bundleID = app.bundleIdentifier,
               knownBundleIDs.contains(bundleID) {
                return true
            }
            return app.localizedName == "Codex"
        }
    }

    @discardableResult
    static func startCodexDesktopApp() -> Int32 {
        run("/usr/bin/open", ["-a", "Codex"])
    }

    @discardableResult
    static func restartCodexDesktopApp() -> Int32 {
        if !isCodexDesktopRunning() {
            return startCodexDesktopApp()
        }

        _ = run("/usr/bin/osascript", ["-e", "tell application \"Codex\" to quit"])
        usleep(700_000)
        return startCodexDesktopApp()
    }

    @discardableResult
    static func openNewCodexCLITerminal() -> Int32 {
        run(
            "/usr/bin/osascript",
            [
                "-e",
                "tell application \"Terminal\" to activate",
                "-e",
                "tell application \"Terminal\" to do script \"codex\""
            ]
        )
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return 1
        }
    }
}

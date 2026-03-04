import AppKit
import Foundation

enum ProcessActions {
    private static let knownBundleIDs: Set<String> = [
        "com.openai.codex",
        "com.openai.chatgpt.codex",
        "com.openai.chatgpt"
    ]

    static func isCodexDesktopRunning() -> Bool {
        !runningCodexDesktopApps().isEmpty
    }

    @discardableResult
    static func startCodexDesktopApp() -> Int32 {
        run("/usr/bin/open", ["-a", "Codex"])
    }

    @discardableResult
    static func restartCodexDesktopApp() -> Int32 {
        if runningCodexDesktopApps().isEmpty {
            return startCodexDesktopApp()
        }

        for app in runningCodexDesktopApps() {
            _ = app.terminate()
        }

        if !waitForCodexDesktopToStop(timeout: 4.0) {
            for app in runningCodexDesktopApps() {
                _ = app.forceTerminate()
            }
            _ = waitForCodexDesktopToStop(timeout: 1.5)
        }

        usleep(200_000)
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

    private static func runningCodexDesktopApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            if let bundleID = app.bundleIdentifier,
               knownBundleIDs.contains(bundleID) {
                return true
            }
            return app.localizedName == "Codex"
        }
    }

    private static func waitForCodexDesktopToStop(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if runningCodexDesktopApps().isEmpty {
                return true
            }
            usleep(100_000)
        }
        return runningCodexDesktopApps().isEmpty
    }
}

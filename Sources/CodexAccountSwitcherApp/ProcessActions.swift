import Foundation

enum ProcessActions {
    @discardableResult
    static func restartCodexDesktopApp() -> Int32 {
        _ = run("/usr/bin/osascript", ["-e", "tell application \"Codex\" to quit"])
        usleep(700_000)
        return run("/usr/bin/open", ["-a", "Codex"])
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

import Foundation
import Sparkle

@MainActor
@Observable
final class UpdaterManager: NSObject, SPUUpdaterDelegate {
    private enum EnvironmentKey {
        static let appcastURL = "CODEX_ACCOUNT_SWITCHER_APPCAST_URL"
    }

    private let configuredFeedURLString: String?
    private var controller: SPUStandardUpdaterController?

    private(set) var isAvailable = false
    private(set) var canCheckForUpdates = false
    private(set) var allowsAutomaticUpdates = false
    private(set) var automaticallyChecksForUpdates = false
    private(set) var automaticallyDownloadsUpdates = false
    private(set) var availabilityNote: String?

    override init() {
        configuredFeedURLString = Self.resolveFeedURLString()
        super.init()
        configureIfPossible()
    }

    func refreshState() {
        syncStateFromUpdater()
    }

    func checkForUpdates() {
        guard let controller else { return }
        controller.checkForUpdates(nil)
        syncStateFromUpdater()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        syncStateFromUpdater()
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard let updater, updater.allowsAutomaticUpdates else { return }
        updater.automaticallyDownloadsUpdates = enabled
        syncStateFromUpdater()
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        configuredFeedURLString
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        syncStateFromUpdater()
    }

    private var updater: SPUUpdater? {
        controller?.updater
    }

    private func configureIfPossible() {
        guard Self.isPackagedApp else {
            availabilityNote = "Updates are available in the packaged app."
            return
        }

        guard let configuredFeedURLString, !configuredFeedURLString.isEmpty else {
            availabilityNote = "Set SUFeedURL in the app bundle to enable updates."
            return
        }

        guard
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") != nil,
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") != nil
        else {
            availabilityNote = "Version metadata is required to enable updates."
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.controller = controller
        controller.startUpdater()
        isAvailable = true
        availabilityNote = nil
        syncStateFromUpdater()
    }

    private func syncStateFromUpdater() {
        guard let updater else {
            canCheckForUpdates = false
            allowsAutomaticUpdates = false
            automaticallyChecksForUpdates = false
            automaticallyDownloadsUpdates = false
            return
        }

        canCheckForUpdates = updater.canCheckForUpdates
        allowsAutomaticUpdates = updater.allowsAutomaticUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }

    private static var isPackagedApp: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    private static func resolveFeedURLString() -> String? {
        if let bundleValue = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
           let trimmed = bundleValue.trimmedNilIfEmpty {
            return trimmed
        }

        if let environmentValue = ProcessInfo.processInfo.environment[EnvironmentKey.appcastURL],
           let trimmed = environmentValue.trimmedNilIfEmpty {
            return trimmed
        }

        return nil
    }
}

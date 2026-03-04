import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    private let profilesStore = ProfilesStore()
    private let authStore = CodexAuthStore()
    private let usageService = UsageService()
    private let usageHistoryStore = UsageHistoryStore()
    private let launchAtLoginManager = LaunchAtLoginManager()
    private var backgroundRefreshTask: Task<Void, Never>?

    var profiles: [CodexAuthProfile] = []
    var activeProfileID: UUID?
    var usageByProfileID: [UUID: UsageSnapshot] = [:]
    var usageHistoryByProfileID: [UUID: [UsageHistoryPoint]] = [:]
    var usageErrorByProfileID: [UUID: String] = [:]
    var actionErrorByProfileID: [UUID: String] = [:]

    var isRefreshingUsage = false
    var isSwitching = false
    var isAddingOAuthProfile = false
    var isGraphMode = false
    var selectedHistoryRange: UsageHistoryRange = .h24
    var openAtLoginEnabled = false
    var lastErrorMessage: String?

    init() {
        loadProfiles()
        loadUsageHistory()
        syncCurrentAuthProfileIfAvailable()
        refreshOpenAtLoginState()
        startBackgroundRefreshLoop()
    }

    var sortedProfiles: [CodexAuthProfile] {
        profiles
    }

    func loadProfiles() {
        do {
            let envelope = try profilesStore.load()
            profiles = envelope.profiles
            activeProfileID = envelope.activeProfileID
            reconcileActiveProfile()
        } catch {
            lastErrorMessage = "Failed to load profiles: \(error.localizedDescription)"
        }
    }

    func saveProfiles() {
        do {
            let envelope = ProfilesEnvelope(profiles: profiles, activeProfileID: activeProfileID)
            try profilesStore.save(envelope)
        } catch {
            lastErrorMessage = "Failed to save profiles: \(error.localizedDescription)"
        }
    }

    func addProfile(_ profile: CodexAuthProfile) {
        appendProfile(profile)
        reconcileActiveProfile(preferredProfileID: profile.id)
        saveProfiles()
    }

    func addProfileViaOAuth() async {
        if isAddingOAuthProfile {
            return
        }

        isAddingOAuthProfile = true
        defer { isAddingOAuthProfile = false }

        do {
            let oauthProfile = try await CodexOAuthService().addProfileViaChatGPTLogin()
            appendProfile(oauthProfile)
            reconcileActiveProfile(preferredProfileID: oauthProfile.id)
            saveProfiles()
            await refreshUsageForAllProfiles()
        } catch {
            lastErrorMessage = "OAuth add failed: \(error.localizedDescription)"
        }
    }

    func updateProfile(_ profile: CodexAuthProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        saveProfiles()
    }

    func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        usageByProfileID[id] = nil
        usageHistoryByProfileID[id] = nil
        usageErrorByProfileID[id] = nil
        actionErrorByProfileID[id] = nil

        if activeProfileID == id {
            activeProfileID = profiles.first?.id
        }

        saveProfiles()
        saveUsageHistory()
    }

    @discardableResult
    func setActiveProfile(id: UUID) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        if activeProfileID == id {
            actionErrorByProfileID[id] = nil
            return true
        }

        isSwitching = true
        defer { isSwitching = false }

        do {
            var profile = profiles[index]
            profile.lastUsedAt = Date()
            profiles[index] = profile

            try authStore.activate(profile: profile)
            activeProfileID = id
            actionErrorByProfileID[id] = nil
            saveProfiles()
            return true
        } catch {
            actionErrorByProfileID[id] = "Switch failed: \(error.localizedDescription)"
            return false
        }
    }

    func importCurrentAuthAsProfile() {
        do {
            let imported = try authStore.importCurrentProfile()
            appendProfile(imported)
            reconcileActiveProfile(preferredProfileID: imported.id)
            saveProfiles()
        } catch {
            lastErrorMessage = "Failed to import current auth: \(error.localizedDescription)"
        }
    }

    func clearError() {
        lastErrorMessage = nil
    }

    func clearTransientErrors() {
        lastErrorMessage = nil
        usageErrorByProfileID.removeAll()
        actionErrorByProfileID.removeAll()
    }

    func refreshOpenAtLoginState() {
        openAtLoginEnabled = launchAtLoginManager.isEnabled()
    }

    func historySeries(for profileID: UUID, range: UsageHistoryRange? = nil) -> [UsageSeriesPoint] {
        let selected = range ?? selectedHistoryRange
        let points = (usageHistoryByProfileID[profileID] ?? []).sorted(by: { $0.timestamp < $1.timestamp })
        guard !points.isEmpty else { return [] }

        let cutoff = Date().addingTimeInterval(-selected.duration)
        let filtered = points.filter { $0.timestamp >= cutoff }

        return filtered.compactMap { point in
            let value: Double?
            if selected.prefersFiveHourWindow {
                value = point.fiveHourUsedPercent ?? point.weeklyUsedPercent
            } else {
                value = point.weeklyUsedPercent ?? point.fiveHourUsedPercent
            }

            guard let value else { return nil }
            return UsageSeriesPoint(
                timestamp: point.timestamp,
                usedPercent: min(max(value, 0), 100)
            )
        }
    }

    func setOpenAtLoginEnabled(_ enabled: Bool) {
        do {
            try launchAtLoginManager.setEnabled(enabled)
            openAtLoginEnabled = launchAtLoginManager.isEnabled()
        } catch {
            openAtLoginEnabled = launchAtLoginManager.isEnabled()
            lastErrorMessage = "Failed to update startup setting: \(error.localizedDescription)"
        }
    }

    private func loadUsageHistory() {
        do {
            let envelope = try usageHistoryStore.load()
            usageHistoryByProfileID = envelope.pointsByProfileID
        } catch {
            usageHistoryByProfileID = [:]
        }
    }

    private func saveUsageHistory() {
        do {
            let envelope = UsageHistoryEnvelope(pointsByProfileID: usageHistoryByProfileID)
            try usageHistoryStore.save(envelope)
        } catch {
            // Keep this silent in UI to avoid noisy persistence errors for background polling.
        }
    }

    private func startBackgroundRefreshLoop() {
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshUsageForAllProfiles()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000) // 5 minutes
                await self.refreshUsageForAllProfiles()
            }
        }
    }

    func refreshUsageForAllProfiles() async {
        if isRefreshingUsage {
            return
        }

        isRefreshingUsage = true
        defer { isRefreshingUsage = false }

        let currentProfiles = profiles
        let usageService = self.usageService
        var historyChanged = false

        await withTaskGroup(of: (UUID, Result<UsageSnapshot, Error>).self) { group in
            for profile in currentProfiles {
                group.addTask {
                    do {
                        let snapshot = try await usageService.fetchUsage(for: profile)
                        return (profile.id, .success(snapshot))
                    } catch {
                        return (profile.id, .failure(error))
                    }
                }
            }

            for await (profileID, result) in group {
                switch result {
                case .success(let snapshot):
                    usageByProfileID[profileID] = snapshot
                    usageErrorByProfileID[profileID] = nil
                    if recordHistoryPoint(profileID: profileID, snapshot: snapshot) {
                        historyChanged = true
                    }
                    if let idx = profiles.firstIndex(where: { $0.id == profileID }),
                       profiles[idx].planType?.trimmedNilIfEmpty == nil {
                        profiles[idx].planType = snapshot.planType
                    }
                case .failure(let error):
                    if !isCancellationError(error) {
                        usageErrorByProfileID[profileID] = "Usage refresh failed: \(error.localizedDescription)"
                    }
                }
            }
        }

        saveProfiles()
        if historyChanged {
            saveUsageHistory()
        }
    }

    @discardableResult
    private func recordHistoryPoint(profileID: UUID, snapshot: UsageSnapshot) -> Bool {
        let point = UsageHistoryPoint(
            timestamp: Date(),
            fiveHourUsedPercent: snapshot.fiveHourWindow?.normalizedUsedPercent,
            weeklyUsedPercent: snapshot.weeklyWindow?.normalizedUsedPercent
        )

        var history = usageHistoryByProfileID[profileID] ?? []
        if let last = history.last,
           abs(last.timestamp.timeIntervalSince(point.timestamp)) < 120 {
            history[history.count - 1] = point
        } else {
            history.append(point)
        }

        let cutoff = Date().addingTimeInterval(-(35 * 24 * 60 * 60))
        history.removeAll { $0.timestamp < cutoff }
        usageHistoryByProfileID[profileID] = history
        return true
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        return error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveContains("cancel")
    }

    private func appendProfile(_ profile: CodexAuthProfile) {
        // Only replace when editing an existing saved profile by the same profile id.
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    private func syncCurrentAuthProfileIfAvailable() {
        guard let current = try? authStore.importCurrentProfile() else {
            return
        }

        if let index = profiles.firstIndex(where: { $0.accountID == current.accountID }) {
            var existing = profiles[index]
            existing.accessToken = current.accessToken
            existing.refreshToken = current.refreshToken
            existing.idToken = current.idToken
            existing.planType = current.planType ?? existing.planType
            existing.email = current.email ?? existing.email
            if existing.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let email = current.email?.trimmingCharacters(in: .whitespacesAndNewlines),
               !email.isEmpty {
                existing.name = email
            }
            profiles[index] = existing
            if activeProfileID == nil {
                activeProfileID = existing.id
            }
        } else {
            profiles.append(current)
            if activeProfileID == nil {
                activeProfileID = current.id
            }
        }

        saveProfiles()
    }

    private func reconcileActiveProfile(preferredProfileID: UUID? = nil) {
        guard !profiles.isEmpty else {
            activeProfileID = nil
            return
        }

        // Keep current selection if it still exists.
        if let activeProfileID,
           profiles.contains(where: { $0.id == activeProfileID }) {
            return
        }

        // Prefer explicit profile when adding/importing new accounts.
        if let preferredProfileID,
           profiles.contains(where: { $0.id == preferredProfileID }) {
            activeProfileID = preferredProfileID
            return
        }

        // Recover active state from what's currently in ~/.codex/auth.json.
        if let current = try? authStore.importCurrentProfile() {
            if let exact = profiles.first(where: {
                $0.accountID == current.accountID && $0.accessToken == current.accessToken
            }) {
                activeProfileID = exact.id
                return
            }

            if let byAccount = profiles.first(where: { $0.accountID == current.accountID }) {
                activeProfileID = byAccount.id
                return
            }
        }

        // Final fallback: first profile is treated as active.
        activeProfileID = profiles.first?.id
    }
}

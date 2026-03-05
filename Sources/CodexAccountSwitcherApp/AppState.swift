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
    var selectedGraphMetric: UsageGraphMetric = .fiveHour
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
            normalizeAndDedupeProfiles()
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

    func historySeries(
        for profileID: UUID,
        range: UsageHistoryRange? = nil,
        metric: UsageGraphMetric? = nil
    ) -> [UsageSeriesPoint] {
        let selected = range ?? selectedHistoryRange
        let selectedMetric = metric ?? selectedGraphMetric
        let points = (usageHistoryByProfileID[profileID] ?? []).sorted(by: { $0.timestamp < $1.timestamp })
        guard !points.isEmpty else { return [] }

        let cutoff = Date().addingTimeInterval(-selected.duration)
        let filtered = points.filter { $0.timestamp >= cutoff }

        let series = filtered.compactMap { point -> (Date, Double)? in
            let usedPercent: Double?
            if selectedMetric == .fiveHour {
                usedPercent = point.fiveHourUsedPercent ?? point.weeklyUsedPercent
            } else {
                usedPercent = point.weeklyUsedPercent ?? point.fiveHourUsedPercent
            }

            guard let usedPercent else { return nil }
            let remaining = min(max(100 - usedPercent, 0), 100)
            return (point.timestamp, remaining)
        }

        guard !series.isEmpty else { return [] }
        let jumpThreshold = resetJumpThreshold(for: selectedMetric)

        var result: [UsageSeriesPoint] = []
        result.reserveCapacity(series.count)

        var previousRemaining: Double?
        var previousTimestamp: Date?

        for sample in series {
            let isResetPoint: Bool
            if let previousRemaining, let previousTimestamp {
                let jump = sample.1 - previousRemaining
                let sampleGap = sample.0.timeIntervalSince(previousTimestamp)
                isResetPoint = jump >= jumpThreshold && sampleGap <= 8 * 60 * 60
            } else {
                isResetPoint = false
            }

            result.append(
                UsageSeriesPoint(
                    timestamp: sample.0,
                    remainingPercent: sample.1,
                    isResetPoint: isResetPoint
                )
            )
            previousRemaining = sample.1
            previousTimestamp = sample.0
        }

        return result
    }

    private func resetJumpThreshold(for metric: UsageGraphMetric) -> Double {
        switch metric {
        case .fiveHour:
            return 10
        case .weekly:
            return 6
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
            return
        }

        if let index = findMatchingProfileIndex(for: profile) {
            let existing = profiles[index]
            profiles[index] = mergeProfile(existing: existing, incoming: profile)
            return
        }

        profiles.append(profile)
    }

    private func syncCurrentAuthProfileIfAvailable() {
        guard let current = try? authStore.importCurrentProfile() else {
            return
        }

        if let index = findMatchingProfileIndex(for: current) {
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

            if let identityMatch = profiles.first(where: { hasSameIdentity($0, current) }) {
                activeProfileID = identityMatch.id
                return
            }
        }

        // Final fallback: first profile is treated as active.
        activeProfileID = profiles.first?.id
    }

    private func normalizeAndDedupeProfiles() {
        guard !profiles.isEmpty else { return }

        var deduped: [CodexAuthProfile] = []
        deduped.reserveCapacity(profiles.count)

        var remappedActiveID = activeProfileID

        for profile in profiles {
            if let existingIndex = deduped.firstIndex(where: { hasSameIdentity($0, profile) }) {
                let existing = deduped[existingIndex]
                deduped[existingIndex] = mergeProfile(existing: existing, incoming: profile)
                if remappedActiveID == profile.id {
                    remappedActiveID = existing.id
                }
            } else {
                deduped.append(profile)
            }
        }

        if deduped != profiles {
            profiles = deduped
            activeProfileID = remappedActiveID
            saveProfiles()
        }
    }

    private func findMatchingProfileIndex(for profile: CodexAuthProfile) -> Int? {
        profiles.firstIndex(where: { hasSameIdentity($0, profile) })
    }

    private func hasSameIdentity(_ lhs: CodexAuthProfile, _ rhs: CodexAuthProfile) -> Bool {
        if let lhsIdentity = identityKey(for: lhs),
           let rhsIdentity = identityKey(for: rhs),
           lhsIdentity == rhsIdentity {
            return true
        }

        if let lhsEmail = lhs.email?.trimmedNilIfEmpty?.lowercased(),
           let rhsEmail = rhs.email?.trimmedNilIfEmpty?.lowercased(),
           lhsEmail == rhsEmail {
            return true
        }

        if let lhsRefresh = lhs.refreshToken?.trimmedNilIfEmpty,
           let rhsRefresh = rhs.refreshToken?.trimmedNilIfEmpty,
           lhsRefresh == rhsRefresh {
            return true
        }

        if let lhsIDToken = lhs.idToken?.trimmedNilIfEmpty,
           let rhsIDToken = rhs.idToken?.trimmedNilIfEmpty,
           lhsIDToken == rhsIDToken {
            return true
        }

        return lhs.accountID == rhs.accountID && lhs.accessToken == rhs.accessToken
    }

    private func identityKey(for profile: CodexAuthProfile) -> String? {
        if let userID = extractUserIdentity(fromIDToken: profile.idToken) {
            return "user:\(userID)"
        }

        if let email = profile.email?.trimmedNilIfEmpty?.lowercased() {
            return "email:\(email)"
        }

        return nil
    }

    private func mergeProfile(existing: CodexAuthProfile, incoming: CodexAuthProfile) -> CodexAuthProfile {
        var merged = existing

        let incomingName = incoming.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !incomingName.isEmpty {
            merged.name = incomingName
        }

        if let email = incoming.email?.trimmedNilIfEmpty {
            merged.email = email
        }

        if let plan = incoming.planType?.trimmedNilIfEmpty {
            merged.planType = plan
        }

        merged.accountID = incoming.accountID
        merged.accessToken = incoming.accessToken
        merged.refreshToken = incoming.refreshToken ?? merged.refreshToken
        merged.idToken = incoming.idToken ?? merged.idToken

        if let incomingLastUsed = incoming.lastUsedAt {
            if let existingLastUsed = merged.lastUsedAt {
                merged.lastUsedAt = max(existingLastUsed, incomingLastUsed)
            } else {
                merged.lastUsedAt = incomingLastUsed
            }
        }

        return merged
    }

    private func extractUserIdentity(fromIDToken idToken: String?) -> String? {
        guard
            let idToken = idToken?.trimmedNilIfEmpty,
            let payload = decodeJWTPayload(idToken)
        else {
            return nil
        }

        if let authNode = payload["https://api.openai.com/auth"] as? [String: Any] {
            if let chatGPTUserID = authNode["chatgpt_user_id"] as? String,
               let value = chatGPTUserID.trimmedNilIfEmpty?.lowercased() {
                return value
            }
            if let userID = authNode["user_id"] as? String,
               let value = userID.trimmedNilIfEmpty?.lowercased() {
                return value
            }
        }

        if let subject = payload["sub"] as? String,
           let value = subject.trimmedNilIfEmpty?.lowercased() {
            return value
        }

        return nil
    }

    private func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = payload.count % 4
        if padding > 0 {
            payload += String(repeating: "=", count: 4 - padding)
        }

        guard
            let data = Data(base64Encoded: payload),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return object
    }
}

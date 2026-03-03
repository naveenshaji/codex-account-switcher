import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    private let profilesStore = ProfilesStore()
    private let authStore = CodexAuthStore()
    private let usageService = UsageService()

    var profiles: [CodexAuthProfile] = []
    var activeProfileID: UUID?
    var usageByProfileID: [UUID: UsageSnapshot] = [:]

    var isRefreshingUsage = false
    var isSwitching = false
    var isAddingOAuthProfile = false
    var lastErrorMessage: String?

    init() {
        loadProfiles()
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

        if activeProfileID == id {
            activeProfileID = profiles.first?.id
        }

        saveProfiles()
    }

    @discardableResult
    func setActiveProfile(id: UUID) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        if activeProfileID == id {
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
            saveProfiles()
            return true
        } catch {
            lastErrorMessage = "Failed to switch profile: \(error.localizedDescription)"
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

    func refreshUsageForAllProfiles() async {
        if isRefreshingUsage {
            return
        }

        isRefreshingUsage = true
        defer { isRefreshingUsage = false }

        let currentProfiles = profiles
        let usageService = self.usageService

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

            var firstError: String?
            for await (profileID, result) in group {
                switch result {
                case .success(let snapshot):
                    usageByProfileID[profileID] = snapshot
                    if let idx = profiles.firstIndex(where: { $0.id == profileID }),
                       profiles[idx].planType?.trimmedNilIfEmpty == nil {
                        profiles[idx].planType = snapshot.planType
                    }
                case .failure(let error):
                    if firstError == nil && !isCancellationError(error) {
                        firstError = error.localizedDescription
                    }
                }
            }

            if let firstError {
                lastErrorMessage = "Some usage requests failed: \(firstError)"
            } else if let lastErrorMessage,
                      lastErrorMessage.hasPrefix("Some usage requests failed:") {
                self.lastErrorMessage = nil
            }
        }

        saveProfiles()
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

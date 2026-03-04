import Foundation

struct CodexAuthProfile: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var email: String?
    var planType: String?
    var accountID: String
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    let createdAt: Date
    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        email: String? = nil,
        planType: String? = nil,
        accountID: String,
        accessToken: String,
        refreshToken: String? = nil,
        idToken: String? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.email = email?.trimmedNilIfEmpty
        self.planType = planType?.trimmedNilIfEmpty
        self.accountID = accountID
        self.accessToken = accessToken
        self.refreshToken = refreshToken?.trimmedNilIfEmpty
        self.idToken = idToken?.trimmedNilIfEmpty
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

struct UsageWindow: Codable, Hashable {
    var limitID: String
    var usedPercent: Double
    var windowDurationMins: Int?
    var resetsAt: Date?

    var normalizedUsedPercent: Double {
        min(max(usedPercent, 0), 100)
    }

    var normalizedRemainingPercent: Double {
        min(max(100 - normalizedUsedPercent, 0), 100)
    }
}

struct UsageSnapshot: Codable, Hashable {
    var planType: String?
    var windows: [UsageWindow]
    var fetchedAt: Date

    var fiveHourWindow: UsageWindow? {
        selectWindow(targetMinutes: 300)
    }

    var weeklyWindow: UsageWindow? {
        selectWindow(targetMinutes: 10_080)
    }

    private func selectWindow(targetMinutes: Int) -> UsageWindow? {
        if let exact = windows.first(where: { $0.windowDurationMins == targetMinutes }) {
            return exact
        }

        let withDuration = windows.compactMap { window -> (UsageWindow, Int)? in
            guard let minutes = window.windowDurationMins else { return nil }
            return (window, abs(minutes - targetMinutes))
        }

        return withDuration.min(by: { $0.1 < $1.1 })?.0
    }
}

struct ProfilesEnvelope: Codable {
    var profiles: [CodexAuthProfile]
    var activeProfileID: UUID?
}

struct UsageHistoryPoint: Codable, Hashable {
    var timestamp: Date
    var fiveHourUsedPercent: Double?
    var weeklyUsedPercent: Double?
}

struct UsageHistoryEnvelope: Codable {
    var pointsByProfileID: [UUID: [UsageHistoryPoint]]
}

struct UsageSeriesPoint: Identifiable, Hashable {
    let timestamp: Date
    let usedPercent: Double

    var id: Date { timestamp }
}

enum UsageHistoryRange: String, CaseIterable, Codable, Identifiable {
    case h1
    case h5
    case h12
    case h24
    case d7
    case d30

    var id: String { rawValue }

    var label: String {
        switch self {
        case .h1: return "1h"
        case .h5: return "5h"
        case .h12: return "12h"
        case .h24: return "24h"
        case .d7: return "7d"
        case .d30: return "30d"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .h1: return 60 * 60
        case .h5: return 5 * 60 * 60
        case .h12: return 12 * 60 * 60
        case .h24: return 24 * 60 * 60
        case .d7: return 7 * 24 * 60 * 60
        case .d30: return 30 * 24 * 60 * 60
        }
    }

    var prefersFiveHourWindow: Bool {
        switch self {
        case .h1, .h5:
            return true
        default:
            return false
        }
    }
}

extension CodexAuthProfile {
    var displayEmail: String {
        if let email = email?.trimmedNilIfEmpty {
            return email
        }
        if let name = name.trimmedNilIfEmpty {
            return name
        }
        return "Unknown email"
    }
}

extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

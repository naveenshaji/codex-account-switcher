import Foundation

struct UsageService: Sendable {
    private let session: URLSession = .shared

    func fetchUsage(for profile: CodexAuthProfile, baseURL: String = "https://chatgpt.com/backend-api") async throws -> UsageSnapshot {
        let normalizedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(normalizedBase)/wham/usage") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(profile.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(profile.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex-account-switcher/0.1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let payload = try decoder.decode(RateLimitStatusPayload.self, from: data)
        return payload.toSnapshot()
    }
}

private struct RateLimitStatusPayload: Decodable {
    var planType: String?
    var rateLimit: RateLimitStatusDetails?
    var additionalRateLimits: [AdditionalRateLimitDetails]?

    func toSnapshot() -> UsageSnapshot {
        var windows: [UsageWindow] = []

        if let details = rateLimit {
            windows.append(contentsOf: details.windows(limitID: "codex"))
        }

        if let additionalRateLimits {
            for additional in additionalRateLimits {
                let id = additional.meteredFeature.trimmedNilIfEmpty ?? "unknown"
                windows.append(contentsOf: additional.rateLimit?.windows(limitID: id) ?? [])
            }
        }

        return UsageSnapshot(
            planType: planType,
            windows: windows,
            fetchedAt: Date()
        )
    }
}

private struct AdditionalRateLimitDetails: Decodable {
    var meteredFeature: String
    var limitName: String?
    var rateLimit: RateLimitStatusDetails?
}

private struct RateLimitStatusDetails: Decodable {
    var primaryWindow: RateLimitWindowSnapshot?
    var secondaryWindow: RateLimitWindowSnapshot?

    func windows(limitID: String) -> [UsageWindow] {
        var result: [UsageWindow] = []

        if let primaryWindow {
            result.append(primaryWindow.toWindow(limitID: limitID))
        }

        if let secondaryWindow {
            result.append(secondaryWindow.toWindow(limitID: limitID))
        }

        return result
    }
}

private struct RateLimitWindowSnapshot: Decodable {
    var usedPercent: Double?
    var limitWindowSeconds: Int?
    var resetAt: Int64?

    func toWindow(limitID: String) -> UsageWindow {
        let minutes: Int? = {
            guard let limitWindowSeconds, limitWindowSeconds > 0 else { return nil }
            return Int(ceil(Double(limitWindowSeconds) / 60.0))
        }()

        let resetDate: Date? = {
            guard let resetAt, resetAt > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(resetAt))
        }()

        return UsageWindow(
            limitID: limitID,
            usedPercent: usedPercent ?? 0,
            windowDurationMins: minutes,
            resetsAt: resetDate
        )
    }
}

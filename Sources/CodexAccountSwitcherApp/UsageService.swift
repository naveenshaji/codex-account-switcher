import Foundation

enum UsageServiceError: LocalizedError {
    case invalidUsageURL
    case invalidResponse
    case httpStatus(code: Int, body: String?)

    var errorDescription: String? {
        switch self {
        case .invalidUsageURL:
            return "Usage endpoint URL is invalid."
        case .invalidResponse:
            return "Usage endpoint returned an invalid response."
        case .httpStatus(let code, let body):
            if let body, !body.isEmpty {
                return "Usage request failed (\(code)): \(body)"
            }
            return "Usage request failed (\(code))."
        }
    }

    var isAuthenticationFailure: Bool {
        switch self {
        case .httpStatus(let code, let body):
            if code == 401 || code == 403 {
                return true
            }

            guard let body = body?.lowercased() else {
                return false
            }

            return body.contains("unauthorized")
                || body.contains("forbidden")
                || body.contains("expired")
                || body.contains("invalid_token")
                || body.contains("login")
                || body.contains("auth")
                || body.contains("session")
        case .invalidUsageURL, .invalidResponse:
            return false
        }
    }
}

struct UsageService: Sendable {
    private let session: URLSession = .shared

    func fetchUsage(for profile: CodexAuthProfile, baseURL: String = "https://chatgpt.com/backend-api") async throws -> UsageSnapshot {
        let normalizedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(normalizedBase)/wham/usage") else {
            throw UsageServiceError.invalidUsageURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(profile.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(profile.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex-account-switcher/0.1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageServiceError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmedNilIfEmpty
            throw UsageServiceError.httpStatus(code: http.statusCode, body: body)
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

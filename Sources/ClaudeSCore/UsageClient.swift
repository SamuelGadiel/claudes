import Foundation

public struct UsageWindow: Decodable, Sendable {
    public let utilization: Double?
    public let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

public struct ExtraUsage: Decodable, Sendable {
    public let isEnabled: Bool
    public let monthlyLimit: Double?
    public let usedCredits: Double?
    public let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }
}

/// Response from GET https://api.anthropic.com/api/oauth/usage — the same
/// endpoint (not publicly documented, but used by Claude Code
/// itself) that feeds its status line. See plans/specs/06.
///
/// The real response carries many more fields than we model here (internal
/// code names like "tangelo", "iguana_necktie" — probably feature
/// flags/experiments, null on the tested accounts) — Codable ignores any
/// undeclared key, so we only list what the panel actually uses.
public struct UsageResponse: Decodable, Sendable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    public let sevenDayOpus: UsageWindow?
    public let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case extraUsage = "extra_usage"
    }
}

/// The API returns ISO 8601 dates with microseconds and a "+00:00" offset
/// (e.g. "2026-10-12T08:59:59.551118+00:00") — JSONDecoder's default
/// formatter (`.iso8601`) doesn't accept fractional seconds, hence the
/// custom parse with fallback.
enum UsageDateParsing {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func decode(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        if let date = withFractionalSeconds.date(from: string) ?? standard.date(from: string) {
            return date
        }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "Date in unexpected format: \(string)"
        )
    }
}


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

/// Resposta de GET https://api.anthropic.com/api/oauth/usage — o mesmo
/// endpoint (não documentado publicamente, mas usado pelo próprio Claude
/// Code) que alimenta a status line dele. Ver plans/specs/06.
///
/// A resposta real traz muito mais campos do que modelamos aqui (nomes de
/// código internos tipo "tangelo", "iguana_necktie" — provavelmente feature
/// flags/experimentos, nulos nas contas testadas) — Codable ignora qualquer
/// chave não declarada, então só listamos o que o painel de fato usa.
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

public enum UsageAPIError: Error, CustomStringConvertible {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case transport(Error)
    case decoding(Error)

    public var description: String {
        switch self {
        case .unauthorized:
            return "token rejeitado pela Anthropic — pode ter expirado ou sido revogado"
        case .rateLimited(let retryAfter):
            return "endpoint de uso com rate limit" + (retryAfter.map { " (retry em \(Int($0))s)" } ?? "")
        case .http(let code):
            return "endpoint de uso retornou HTTP \(code)"
        case .transport(let error):
            return "erro de rede: \(error.localizedDescription)"
        case .decoding(let error):
            return "erro ao decodificar resposta: \(error)"
        }
    }
}

/// A API retorna datas ISO 8601 com microssegundos e offset "+00:00"
/// (ex.: "2026-10-12T08:59:59.551118+00:00") — o formatador padrão do
/// JSONDecoder (`.iso8601`) não aceita fração de segundo, por isso o parse
/// customizado com fallback.
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
            in: container, debugDescription: "Data em formato inesperado: \(string)"
        )
    }
}

public enum UsageAPIClient {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public static func fetch(accessToken: String) async throws -> UsageResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeSwitcher/0.1 (macOS menu bar)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageAPIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageAPIError.transport(URLError(.badServerResponse))
        }

        switch http.statusCode {
        case 200:
            break
        case 401:
            throw UsageAPIError.unauthorized
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw UsageAPIError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageAPIError.http(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { try UsageDateParsing.decode($0) }
        do {
            return try decoder.decode(UsageResponse.self, from: data)
        } catch {
            throw UsageAPIError.decoding(error)
        }
    }
}

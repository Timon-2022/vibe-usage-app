import Foundation

struct UsageBucket: Codable, Identifiable, Equatable {
    var id: String {
        "\(bucketStart)-\(source)-\(model)-\(project)-\(hostname)"
    }

    let source: String
    let model: String
    let project: String
    let hostname: String
    let bucketStart: String
    let inputTokens: Int
    let outputTokens: Int
    /// Not yet emitted by the sync pipeline (collector and server track only
    /// cache reads); optional so decoding keeps working once it appears.
    let cacheCreationInputTokens: Int?
    let cachedInputTokens: Int
    let reasoningOutputTokens: Int
    let totalTokens: Int
    let estimatedCost: Double?

    /// Total token volume, matching the web dashboard and ccusage-style totals:
    /// input + output + reasoning + cached input.
    var computedTotal: Int {
        inputTokens + outputTokens + reasoningOutputTokens + cachedInputTokens
    }

    /// Absolute instant parsed from the API's ISO-8601 bucket timestamp.
    var date: Date? {
        Formatters.dateFromISO8601(bucketStart)
    }

    /// Gregorian calendar-day key in the viewer's timezone.
    var dayKey: String {
        dayKey(in: .current)
    }

    func dayKey(in timeZone: TimeZone) -> String {
        Formatters.localDayKey(bucketStart, timeZone: timeZone)
    }

    /// Hour string (yyyy-MM-ddTHH) for hourly grouping
    var hourKey: String {
        String(bucketStart.prefix(13))
    }
}

struct UsageResponse: Codable {
    let buckets: [UsageBucket]
    let sessions: [UsageSession]?
    let hasAnyData: Bool
}

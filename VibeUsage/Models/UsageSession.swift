import Foundation

struct UsageSession: Codable, Identifiable, Equatable {
    var id: String {
        "\(source)-\(firstMessageAt)-\(project)"
    }

    let source: String
    let project: String
    let hostname: String
    let firstMessageAt: String
    let lastMessageAt: String
    let durationSeconds: Int
    let activeSeconds: Int
    let messageCount: Int
    let userMessageCount: Int

    /// Gregorian calendar-day key in the viewer's timezone.
    var dayKey: String {
        dayKey(in: .current)
    }

    func dayKey(in timeZone: TimeZone) -> String {
        Formatters.localDayKey(firstMessageAt, timeZone: timeZone)
    }

    /// Hour string (yyyy-MM-ddTHH) from firstMessageAt for hourly grouping.
    /// Hourly range keys deliberately stay in UTC to match the API buckets.
    var hourKey: String {
        String(firstMessageAt.prefix(13))
    }

    /// Absolute instant parsed from `firstMessageAt`.
    var date: Date? {
        Formatters.dateFromISO8601(firstMessageAt)
    }
}

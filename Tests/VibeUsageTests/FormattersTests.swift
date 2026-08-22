import Foundation
import Testing
@testable import VibeUsage

struct FormattersTests {
    @Test
    func relativeTimeUsesTimelineDateInsteadOfWallClock() {
        let producedAt = Date(timeIntervalSince1970: 1_000)
        let timelineDate = producedAt.addingTimeInterval(6 * 60)

        #expect(
            Formatters.formatRelativeTime(producedAt, relativeTo: timelineDate)
                == "6 分钟前"
        )
    }

    @Test
    func dailyUsageKeysUseTheViewerTimezone() throws {
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let bucket = UsageBucket(
            source: "codex",
            model: "gpt-5",
            project: "vibe-usage",
            hostname: "mac",
            bucketStart: "2026-08-21T16:00:00.000Z",
            inputTokens: 1,
            outputTokens: 0,
            cacheCreationInputTokens: nil,
            cachedInputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: 1,
            estimatedCost: nil
        )
        let session = UsageSession(
            source: "codex",
            project: "vibe-usage",
            hostname: "mac",
            firstMessageAt: "2026-08-21T16:30:00.000Z",
            lastMessageAt: "2026-08-21T16:35:00.000Z",
            durationSeconds: 300,
            activeSeconds: 300,
            messageCount: 2,
            userMessageCount: 1
        )

        #expect(bucket.dayKey(in: shanghai) == "2026-08-22")
        #expect(session.dayKey(in: shanghai) == "2026-08-22")
        #expect(bucket.dayKey(in: utc) == "2026-08-21")
    }

    @Test
    func ChineseSummaryUnitsMatchTheWindowsApp() {
        #expect(Formatters.formatCnyCost(1.25) == "￥8.75")
        #expect(Formatters.formatChineseTokens(1_000) == "1千")
        #expect(Formatters.formatChineseTokens(9_995_000) == "1千万")
        #expect(Formatters.formatChineseTokens(100_000_000) == "1亿")
    }
}

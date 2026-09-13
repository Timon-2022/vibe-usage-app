import Foundation
import Testing
@testable import VibeUsage

struct CommandCodeUsageProbeTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func parsesFiveHourAndWeeklyWindowsAndPlan() throws {
        let credits = try json("""
        {
          "windowLimits": {
            "limited": true,
            "exceeded": false,
            "fiveHour": { "used": 3, "cap": 14, "exceeded": false, "resetAt": 1700001800000 },
            "weekly": { "used": 14.89, "cap": 35, "exceeded": false, "resetAt": 1700600000000 }
          }
        }
        """)
        let subscriptions = try json("""
        { "success": true, "data": { "planId": "individual-goat", "status": "active" } }
        """)

        let snapshot = try #require(CommandCodeUsageProbe.parse(
            creditsData: credits,
            subscriptionsData: subscriptions,
            now: now
        ))

        #expect(snapshot.provider == .commandCode)
        #expect(snapshot.status == .ok)
        #expect(snapshot.planLabel == "GOAT")
        #expect(snapshot.fiveHour?.utilization == 3.0 / 14.0 * 100.0)
        #expect(snapshot.sevenDay?.utilization == 14.89 / 35.0 * 100.0)
        #expect(snapshot.fiveHour?.windowDuration == TimeInterval(5 * 60 * 60))
        #expect(snapshot.sevenDay?.windowDuration == TimeInterval(7 * 24 * 60 * 60))
        #expect(snapshot.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_700_001_800))
    }

    @Test
    func zeroOrPastResetDoesNotAdvertiseCountdownDuration() throws {
        let credits = try json("""
        {
          "windowLimits": {
            "limited": true,
            "fiveHour": { "used": 4, "cap": 10, "resetAt": 0 },
            "weekly": { "used": 5, "cap": 20, "resetAt": 1699999999000 }
          }
        }
        """)

        let snapshot = try #require(CommandCodeUsageProbe.parseCreditsResponse(
            credits,
            planID: "individual-go",
            now: now
        ))

        #expect(snapshot.fiveHour?.utilization == 40)
        #expect(snapshot.fiveHour?.resetsAt == nil)
        #expect(snapshot.fiveHour?.windowDuration == nil)
        #expect(snapshot.sevenDay?.resetsAt == nil)
        #expect(snapshot.sevenDay?.windowDuration == nil)
        #expect(snapshot.planLabel == "Go")
    }

    @Test
    func unlimitedCreditsAreQuietNoData() throws {
        let credits = try json("""
        { "windowLimits": { "limited": false, "exceeded": false } }
        """)
        let snapshot = try #require(CommandCodeUsageProbe.parseCreditsResponse(
            credits,
            planID: "individual-pro",
            now: now
        ))

        #expect(snapshot.provider == .commandCode)
        #expect(snapshot.status == .noData)
        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.sevenDay == nil)
        #expect(snapshot.planLabel == "Pro")
    }

    @Test
    func knownAndUnknownPlanIDsHaveReadableLabels() {
        #expect(CommandCodeUsageProbe.formatPlanLabel("individual-go") == "Go")
        #expect(CommandCodeUsageProbe.formatPlanLabel("individual-goat") == "GOAT")
        #expect(CommandCodeUsageProbe.formatPlanLabel("individual-pro") == "Pro")
        #expect(CommandCodeUsageProbe.formatPlanLabel("individual-pro-v1") == "Pro")
        #expect(CommandCodeUsageProbe.formatPlanLabel("individual-provider") == "Provider")
        #expect(CommandCodeUsageProbe.formatPlanLabel("individual-max") == "Max")
        #expect(CommandCodeUsageProbe.formatPlanLabel("individual-ultra") == "Ultra")
        #expect(CommandCodeUsageProbe.formatPlanLabel("teams-pro") == "Teams Pro")
        #expect(CommandCodeUsageProbe.formatPlanLabel("enterprise-v2") == "Enterprise V2")
    }

    @Test
    func environmentAPIKeyTakesPrecedenceOverAuthFile() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-usage-commandcode-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".commandcode"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"apiKey":"file-placeholder"}"#.utf8)
            .write(to: home.appendingPathComponent(".commandcode/auth.json"))

        #expect(CommandCodeUsageProbe.loadAPIKey(
            homeDirectory: home,
            environment: ["COMMAND_CODE_API_KEY": "env-placeholder"]
        ) == "env-placeholder")
        #expect(CommandCodeUsageProbe.loadAPIKey(
            homeDirectory: home,
            environment: [:]
        ) == "file-placeholder")
        #expect(CommandCodeUsageProbe.loadAPIKey(
            homeDirectory: home,
            environment: ["COMMAND_CODE_API_KEY": "   "]
        ) == "file-placeholder")
    }

    @Test
    func fetchUsesBearerGETForCreditsAndSubscriptions() async throws {
        let credits = try json("""
        {
          "windowLimits": {
            "limited": true,
            "fiveHour": { "used": 1, "cap": 10, "resetAt": 1700001800000 },
            "weekly": { "used": 2, "cap": 20, "resetAt": 1700600000000 }
          }
        }
        """)
        let subscriptions = try json("""
        { "success": true, "data": { "planId": "individual-pro-v1" } }
        """)
        let recorder = RequestRecorder()

        let snapshot = try await CommandCodeUsageProbe.fetch(
            now: now,
            environment: ["COMMAND_CODE_API_KEY": "test-placeholder"],
            baseURL: URL(string: "https://example.test")!,
            requester: { request in
                await recorder.record(request)
                if request.url?.path.hasSuffix("/credits") == true {
                    return CommandCodeUsageProbe.HTTPResponse(data: credits, statusCode: 200)
                }
                return CommandCodeUsageProbe.HTTPResponse(data: subscriptions, statusCode: 200)
            }
        )

        let requests = await recorder.requests
        #expect(snapshot.planLabel == "Pro")
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-placeholder"
        })
        #expect(requests.map { $0.url?.path } == [
            "/alpha/billing/credits",
            "/alpha/billing/subscriptions"
        ])
        #expect(requests.allSatisfy { $0.timeoutInterval == 10 })
    }

    @Test
    func subscriptionEndpointFailureDoesNotEraseValidCredits() async throws {
        let credits = try json("""
        {
          "windowLimits": {
            "limited": true,
            "fiveHour": { "used": 1, "cap": 10, "resetAt": 1700001800000 },
            "weekly": { "used": 2, "cap": 20, "resetAt": 1700600000000 }
          }
        }
        """)

        let snapshot = try await CommandCodeUsageProbe.fetch(
            now: now,
            environment: ["COMMAND_CODE_API_KEY": "test-placeholder"],
            baseURL: URL(string: "https://example.test")!,
            requester: { request in
                if request.url?.path.hasSuffix("/credits") == true {
                    return CommandCodeUsageProbe.HTTPResponse(data: credits, statusCode: 200)
                }
                return CommandCodeUsageProbe.HTTPResponse(data: Data(), statusCode: 503)
            }
        )

        #expect(snapshot.status == .ok)
        #expect(snapshot.fiveHour?.utilization == 10)
        #expect(snapshot.planLabel == nil)
    }

    @Test
    func missingCredentialsAreClassifiedAsAbsent() async {
        do {
            _ = try await CommandCodeUsageProbe.fetch(
                homeDirectory: URL(fileURLWithPath: "/tmp/vibe-usage-no-commandcode-auth"),
                environment: [:],
                requester: { _ in
                    Issue.record("request must not run without credentials")
                    return CommandCodeUsageProbe.HTTPResponse(data: Data(), statusCode: 200)
                }
            )
            Issue.record("expected missing credentials")
        } catch let error as CommandCodeUsageProbe.FetchError {
            #expect(error == .noCredentials)
            #expect(error.rateLimitFailure == .absent)
        } catch {
            Issue.record("unexpected error type")
        }
    }

    private func json(_ string: String) throws -> Data {
        try #require(string.data(using: .utf8))
    }
}

private actor RequestRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }
}

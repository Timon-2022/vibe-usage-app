import Foundation

/// Reads CommandCode's subscription windows without starting an interactive
/// model session. CommandCode's CLI exposes the same information through its
/// `/usage` command, while the billing endpoints provide a small, read-only
/// JSON surface that is suitable for a menu-bar refresh.
///
/// The API key is used only for the two in-memory requests. It is never logged,
/// written to Vibe Usage configuration, or sent to the Vibe Usage backend.
enum CommandCodeUsageProbe {
    static let apiBaseURL = URL(string: "https://api.commandcode.ai")!

    struct HTTPResponse: Sendable {
        let data: Data
        let statusCode: Int
    }

    typealias Requester = @Sendable (URLRequest) async throws -> HTTPResponse

    enum FetchError: Error, Equatable, RateLimitFetchError {
        case noCredentials
        case unauthorized
        case transport
        case badResponse(Int)
        case unparseable

        var rateLimitFailure: RateLimitFetchFailure {
            switch self {
            case .noCredentials: return .absent
            case .unauthorized: return .unauthorized
            case .transport, .badResponse, .unparseable: return .transient
            }
        }
    }

    private struct SubscriptionInfo {
        var planID: String?
    }

    private static let fiveHourDuration: TimeInterval = 5 * 60 * 60
    private static let weeklyDuration: TimeInterval = 7 * 24 * 60 * 60

    /// Fetch both credits and subscription metadata. `homeDirectory` and
    /// `environment` are injectable so auth precedence can be tested without
    /// touching the user's real CommandCode credentials.
    static func fetch(
        now: Date = Date(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        baseURL: URL = apiBaseURL,
        requester: Requester = send
    ) async throws -> ProviderRateLimit {
        guard let apiKey = loadAPIKey(homeDirectory: homeDirectory, environment: environment) else {
            throw FetchError.noCredentials
        }

        let credits = try await get(
            path: "/alpha/billing/credits",
            apiKey: apiKey,
            baseURL: baseURL,
            requester: requester
        )
        let subscriptionData: Data?
        do {
            subscriptionData = try await get(
                path: "/alpha/billing/subscriptions",
                apiKey: apiKey,
                baseURL: baseURL,
                requester: requester
            ).data
        } catch is CancellationError {
            throw CancellationError()
        } catch FetchError.unauthorized {
            // A 401/403 means the same bearer credential is no longer
            // authorized; preserve the actionable auth classification instead
            // of presenting a misleading partial plan snapshot.
            throw FetchError.unauthorized
        } catch {
            // Billing metadata is optional for the card. A credits response
            // can still render accurate percentages when this endpoint is
            // temporarily unavailable or changes shape.
            subscriptionData = nil
        }

        guard var snapshot = parseCreditsResponse(
            credits.data,
            now: now
        ) else {
            throw FetchError.unparseable
        }
        if let subscriptionData,
           let subscription = parseSubscriptionResponse(subscriptionData) {
            snapshot.planLabel = formatPlanLabel(subscription.planID)
        }
        try Task.checkCancellation()
        return snapshot
    }

    /// Parse the two CommandCode response bodies into the provider-neutral
    /// model used by Codex and Claude. This method never receives credentials.
    static func parse(
        creditsData: Data,
        subscriptionsData: Data,
        now: Date = Date()
    ) -> ProviderRateLimit? {
        guard var snapshot = parseCreditsResponse(creditsData, now: now) else {
            return nil
        }
        // Credits are the essential quota response. Subscription metadata is
        // best-effort: a temporary billing endpoint failure must not erase
        // otherwise valid 5h/7d percentages; the plan badge simply disappears
        // until the next successful refresh.
        if let subscription = parseSubscriptionResponse(subscriptionsData) {
            snapshot.planLabel = formatPlanLabel(subscription.planID)
        }
        return snapshot
    }

    /// Parse only the credits body. Kept separate from the HTTP code so schema
    /// changes can be covered by fixture tests without making network calls.
    static func parseCreditsResponse(
        _ data: Data,
        planID: String? = nil,
        now: Date = Date()
    ) -> ProviderRateLimit? {
        guard let root = jsonObject(data),
              let limits = root["windowLimits"] as? [String: Any],
              let limited = limits["limited"] as? Bool else {
            return nil
        }

        let planLabel = formatPlanLabel(planID)
        guard limited else {
            return ProviderRateLimit(
                provider: .commandCode,
                planLabel: planLabel,
                status: .noData,
                fetchedAt: now,
                dataAsOf: now
            )
        }

        let fiveHour: RateLimitWindow?
        if let raw = limits["fiveHour"], !(raw is NSNull) {
            guard let parsed = parseWindow(raw, duration: fiveHourDuration, now: now) else {
                return nil
            }
            fiveHour = parsed
        } else {
            fiveHour = nil
        }

        let weekly: RateLimitWindow?
        if let raw = limits["weekly"], !(raw is NSNull) {
            guard let parsed = parseWindow(raw, duration: weeklyDuration, now: now) else {
                return nil
            }
            weekly = parsed
        } else {
            weekly = nil
        }

        guard fiveHour != nil || weekly != nil else { return nil }
        return ProviderRateLimit(
            provider: .commandCode,
            fiveHour: fiveHour,
            sevenDay: weekly,
            planLabel: planLabel,
            status: .ok,
            fetchedAt: now,
            dataAsOf: now
        )
    }

    /// CommandCode plan IDs are stable for the named tiers, but an unknown
    /// future tier should still be readable in the badge instead of vanishing.
    static func formatPlanLabel(_ planID: String?) -> String? {
        guard let planID, !planID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        switch planID.lowercased() {
        case "individual-go": return "Go"
        case "individual-goat": return "GOAT"
        case "individual-pro", "individual-pro-v1": return "Pro"
        case "individual-provider": return "Provider"
        case "individual-max": return "Max"
        case "individual-ultra": return "Ultra"
        case "teams-pro": return "Teams Pro"
        default:
            let words = planID
                .replacingOccurrences(of: "_", with: "-")
                .split(separator: "-")
                .map(String.init)
                .filter { !$0.isEmpty }
            guard !words.isEmpty else { return "Plan" }
            return words.map { word in
                guard let first = word.first else { return word }
                return first.uppercased() + word.dropFirst()
            }.joined(separator: " ")
        }
    }

    /// Environment credentials take precedence over the CLI's auth file, so a
    /// user can point the app at a different CommandCode account for one run.
    /// The returned value remains in memory only.
    static func loadAPIKey(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        for name in ["COMMAND_CODE_API_KEY", "COMMANDCODE_API_KEY"] {
            if let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }

        let authURL = homeDirectory
            .appendingPathComponent(".commandcode")
            .appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL) else { return nil }
        return parseAuthFile(data)
    }

    static func parseAuthFile(_ data: Data) -> String? {
        guard let root = jsonObject(data) else { return nil }
        for key in ["apiKey", "api_key"] {
            if let value = root[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func get(
        path: String,
        apiKey: String,
        baseURL: URL,
        requester: Requester
    ) async throws -> HTTPResponse {
        var url = baseURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VibeUsage/\(AppConfig.version)", forHTTPHeaderField: "User-Agent")

        let response: HTTPResponse
        do {
            response = try await requester(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FetchError.transport
        }

        if response.statusCode == 401 || response.statusCode == 403 {
            throw FetchError.unauthorized
        }
        guard (200..<300).contains(response.statusCode) else {
            throw FetchError.badResponse(response.statusCode)
        }
        return response
    }

    private static func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return HTTPResponse(
                data: data,
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FetchError.transport
        }
    }

    private static func parseSubscriptionResponse(_ data: Data) -> SubscriptionInfo? {
        guard let root = jsonObject(data),
              let success = root["success"] as? Bool else {
            return nil
        }
        // A valid unsuccessful response means there is no active plan. It is
        // different from malformed JSON and should remain a quiet no-data card.
        guard success else { return SubscriptionInfo(planID: nil) }
        guard let info = root["data"] as? [String: Any] else { return nil }
        let planID = (info["planId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SubscriptionInfo(planID: planID?.isEmpty == false ? planID : nil)
    }

    private static func parseWindow(
        _ raw: Any,
        duration: TimeInterval,
        now: Date
    ) -> RateLimitWindow? {
        guard let dict = raw as? [String: Any],
              let used = number(dict["used"]),
              let cap = number(dict["cap"]),
              cap > 0,
              used.isFinite,
              cap.isFinite else {
            return nil
        }

        let resetDate: Date?
        if let resetAt = number(dict["resetAt"]), resetAt > 0, resetAt.isFinite {
            resetDate = Date(timeIntervalSince1970: resetAt / 1000)
        } else {
            resetDate = nil
        }
        let futureReset = resetDate.map { $0 > now } == true

        return RateLimitWindow(
            utilization: min(max(used / cap * 100, 0), 100),
            resetsAt: futureReset ? resetDate : nil,
            windowDuration: futureReset ? duration : nil
        )
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}

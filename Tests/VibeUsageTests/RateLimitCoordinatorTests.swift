import Foundation
import Testing
@testable import VibeUsage

struct RateLimitCoordinatorTests {
    private func snapshot(
        utilization: Double,
        dataAsOf: Date?,
        fetchedAt: Date? = nil,
        status: ProviderRateLimit.Status = .ok
    ) -> ProviderRateLimit {
        ProviderRateLimit(
            provider: .codex,
            sevenDay: RateLimitWindow(utilization: utilization),
            status: status,
            fetchedAt: fetchedAt,
            dataAsOf: dataAsOf
        )
    }

    @Test
    func newerFallbackMayReplaceCurrentSnapshot() {
        let current = snapshot(
            utilization: 40,
            dataAsOf: Date(timeIntervalSince1970: 100)
        )
        let fallback = snapshot(
            utilization: 50,
            dataAsOf: Date(timeIntervalSince1970: 200)
        )

        #expect(RateLimitCoordinator.isNewerSnapshot(fallback, than: current))
    }

    @Test
    func olderFallbackCannotMakeDisplayedDataGoBackwards() {
        let current = snapshot(
            utilization: 50,
            dataAsOf: Date(timeIntervalSince1970: 200)
        )
        let fallback = snapshot(
            utilization: 40,
            dataAsOf: Date(timeIntervalSince1970: 100)
        )

        #expect(!RateLimitCoordinator.isNewerSnapshot(fallback, than: current))
    }

    @Test
    func fetchedAtIsUsedOnlyWhenDataAsOfIsUnavailable() {
        let current = snapshot(
            utilization: 40,
            dataAsOf: nil,
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let fallback = snapshot(
            utilization: 50,
            dataAsOf: nil,
            fetchedAt: Date(timeIntervalSince1970: 200)
        )

        #expect(RateLimitCoordinator.isNewerSnapshot(fallback, than: current))
    }

    @Test
    func nonOkFallbackNeverReplacesCurrentData() {
        let fallback = snapshot(
            utilization: 0,
            dataAsOf: Date(timeIntervalSince1970: 200),
            status: .noData
        )

        #expect(!RateLimitCoordinator.isNewerSnapshot(fallback, than: nil))
    }

    @Test @MainActor
    func concurrentCodexRefreshesShareOneLiveRequest() async {
        let appState = AppState()
        var fetchCount = 0
        let producedAt = Date(timeIntervalSince1970: 200)
        let live = snapshot(utilization: 50, dataAsOf: producedAt)
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchCodexLive: {
                fetchCount += 1
                try await Task.sleep(for: .milliseconds(50))
                return live
            },
            loadCodexCache: { nil },
            readCodexFallback: {
                ProviderRateLimit(provider: .codex, status: .noData)
            }
        )

        let first = Task { @MainActor in await coordinator.refreshCodex() }
        let second = Task { @MainActor in await coordinator.refreshCodex() }
        await first.value
        await second.value

        #expect(fetchCount == 1)
        #expect(appState.rateLimits.first(where: { $0.provider == .codex }) == live)
        #expect(!appState.isCodexRateLimitRefreshing)
    }

    @Test @MainActor
    func closingPanelCancelsCodexRefreshWithoutPublishingLateData() async {
        let appState = AppState()
        var requestStarted = false
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchCodexLive: {
                requestStarted = true
                try await Task.sleep(for: .seconds(30))
                return self.snapshot(
                    utilization: 99,
                    dataAsOf: Date(timeIntervalSince1970: 300)
                )
            },
            loadCodexCache: { nil },
            readCodexFallback: {
                ProviderRateLimit(provider: .codex, status: .noData)
            }
        )

        let refresh = Task { @MainActor in await coordinator.refreshCodex() }
        while !requestStarted { await Task.yield() }
        #expect(appState.isCodexRateLimitRefreshing)

        coordinator.panelVisibilityChanged(visible: false)
        await refresh.value

        #expect(!appState.isCodexRateLimitRefreshing)
        #expect(appState.rateLimits.first(where: { $0.provider == .codex }) == nil)
    }

    /// A genuine endpoint failure with no usable fallback must remain visible;
    /// treating it as `.noData` hides the card and makes retry unreachable.
    @Test @MainActor
    func codexTransportFailureWithoutFallbackSurfacesRetryableError() async {
        let appState = AppState()
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchCodexLive: {
                throw CodexUsageAPI.FetchError.transport(URLError(.notConnectedToInternet))
            },
            loadCodexCache: { nil },
            readCodexFallback: {
                ProviderRateLimit(provider: .codex, status: .noData)
            }
        )

        await coordinator.refreshCodex()

        #expect(
            appState.rateLimits.first(where: { $0.provider == .codex })?.status
                == .retryableError
        )
    }

    /// A machine with no Codex OAuth login and no sessions is an absent feature,
    /// not a noisy network error; preserve the compact `.noData` treatment.
    @Test @MainActor
    func missingCodexLoginWithoutFallbackStaysQuiet() async {
        let appState = AppState()
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchCodexLive: { throw CodexUsageAPI.FetchError.notLoggedIn },
            loadCodexCache: { nil },
            readCodexFallback: {
                ProviderRateLimit(provider: .codex, status: .noData)
            }
        )

        await coordinator.refreshCodex()

        #expect(
            appState.rateLimits.first(where: { $0.provider == .codex })?.status == .noData
        )
    }

    private func claudeSnapshot(
        utilization: Double,
        dataAsOf: Date?
    ) -> ProviderRateLimit {
        ProviderRateLimit(
            provider: .claudeCode,
            fiveHour: RateLimitWindow(utilization: utilization),
            status: .ok,
            fetchedAt: dataAsOf,
            dataAsOf: dataAsOf
        )
    }

    /// The cold-open contract: the on-disk cache paints first so the card is
    /// never blank during the probe's ~2.5s round trip, then the live reading
    /// replaces it.
    @Test @MainActor
    func claudeCachePaintsBeforeLiveProbeReplacesIt() async {
        let appState = AppState()
        appState.claudeRateLimitEnabled = true
        var paintedWhileProbing: ProviderRateLimit?

        let cached = claudeSnapshot(
            utilization: 10,
            dataAsOf: Date(timeIntervalSince1970: 100)
        )
        let live = claudeSnapshot(
            utilization: 42,
            dataAsOf: Date(timeIntervalSince1970: 200)
        )

        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchClaudeLive: {
                paintedWhileProbing = appState.rateLimits.first { $0.provider == .claudeCode }
                return live
            },
            loadClaudeCache: { cached }
        )

        await coordinator.refreshClaude()

        #expect(paintedWhileProbing == cached)
        #expect(appState.rateLimits.first { $0.provider == .claudeCode } == live)
        #expect(!appState.isClaudeRateLimitRefreshing)
    }

    /// A failing probe must not blank a card the cache already filled — the
    /// 「数据截至」 footer states the age honestly instead.
    @Test @MainActor
    func claudeProbeFailureKeepsCachedSnapshot() async {
        let appState = AppState()
        appState.claudeRateLimitEnabled = true
        let cached = claudeSnapshot(
            utilization: 10,
            dataAsOf: Date(timeIntervalSince1970: 100)
        )

        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchClaudeLive: { throw ClaudeUsageProbe.ProbeError.noBinary },
            loadClaudeCache: { cached }
        )

        await coordinator.refreshClaude()

        #expect(appState.rateLimits.first { $0.provider == .claudeCode } == cached)
    }

    /// If a Claude executable exists but the live probe fails and no cache can
    /// paint, surface the retryable card instead of collapsing it as no data.
    @Test @MainActor
    func claudeProbeFailureWithoutCacheSurfacesRetryableError() async {
        let appState = AppState()
        appState.claudeRateLimitEnabled = true
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchClaudeLive: { throw ClaudeUsageProbe.ProbeError.timedOut },
            loadClaudeCache: { nil }
        )

        await coordinator.refreshClaude()

        #expect(
            appState.rateLimits.first(where: { $0.provider == .claudeCode })?.status
                == .retryableError
        )
    }

    /// Not having Claude installed is expected on many Macs and should retain
    /// the quiet capability notice rather than looking like an app failure.
    @Test @MainActor
    func missingClaudeInstallationWithoutCacheStaysQuiet() async {
        let appState = AppState()
        appState.claudeRateLimitEnabled = true
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchClaudeLive: { throw ClaudeUsageProbe.ProbeError.noBinary },
            loadClaudeCache: { nil }
        )

        await coordinator.refreshClaude()

        #expect(
            appState.rateLimits.first(where: { $0.provider == .claudeCode })?.status == .noData
        )
    }

    /// A cached subscription snapshot must survive a later `.notApplicable`
    /// probe result. Claude Desktop can have a fresh plan-usage cache while
    /// the Claude Code process reports `rate_limits_available: false` (for
    /// example when its auth context is different). The live result must not
    /// erase the data already painted from disk.
    @Test @MainActor
    func claudeNotApplicableAfterFreshCacheKeepsCachedSnapshot() async {
        let appState = AppState()
        appState.claudeRateLimitEnabled = true
        let cached = self.claudeSnapshot(
            utilization: 10,
            dataAsOf: Date(timeIntervalSince1970: 100)
        )
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchClaudeLive: { throw ClaudeUsageProbe.ProbeError.limitsNotApplicable },
            loadClaudeCache: { cached }
        )

        await coordinator.refreshClaude()

        #expect(appState.rateLimits.first { $0.provider == .claudeCode } == cached)
    }

    private func commandCodeSnapshot(
        utilization: Double,
        dataAsOf: Date?
    ) -> ProviderRateLimit {
        ProviderRateLimit(
            provider: .commandCode,
            fiveHour: RateLimitWindow(
                utilization: utilization,
                resetsAt: Date(timeIntervalSince1970: 500),
                windowDuration: 5 * 60 * 60
            ),
            sevenDay: RateLimitWindow(
                utilization: utilization,
                resetsAt: Date(timeIntervalSince1970: 500),
                windowDuration: 7 * 24 * 60 * 60
            ),
            planLabel: "GOAT",
            status: .ok,
            fetchedAt: dataAsOf,
            dataAsOf: dataAsOf
        )
    }

    @Test @MainActor
    func concurrentCommandCodeRefreshesShareOneLiveRequest() async {
        let appState = AppState()
        appState.commandCodeRateLimitEnabled = true
        var fetchCount = 0
        let live = commandCodeSnapshot(
            utilization: 42,
            dataAsOf: Date(timeIntervalSince1970: 200)
        )
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchCommandCodeLive: {
                fetchCount += 1
                try await Task.sleep(for: .milliseconds(50))
                return live
            }
        )

        let first = Task { @MainActor in await coordinator.refreshCommandCode() }
        let second = Task { @MainActor in await coordinator.refreshCommandCode() }
        await first.value
        await second.value

        #expect(fetchCount == 1)
        #expect(appState.rateLimits.first { $0.provider == .commandCode } == live)
        #expect(!appState.isCommandCodeRateLimitRefreshing)
    }

    @Test @MainActor
    func commandCodeMissingCredentialsStaysQuietWithoutCache() async {
        let appState = AppState()
        appState.commandCodeRateLimitEnabled = true
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchCommandCodeLive: { throw CommandCodeUsageProbe.FetchError.noCredentials }
        )

        await coordinator.refreshCommandCode()

        #expect(
            appState.rateLimits.first(where: { $0.provider == .commandCode })?.status == .noData
        )
    }

    @Test @MainActor
    func commandCodeNetworkFailureWithoutCacheSurfacesRetryableError() async {
        let appState = AppState()
        appState.commandCodeRateLimitEnabled = true
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchCommandCodeLive: { throw CommandCodeUsageProbe.FetchError.transport }
        )

        await coordinator.refreshCommandCode()

        #expect(
            appState.rateLimits.first(where: { $0.provider == .commandCode })?.status
                == .retryableError
        )
    }

    @Test @MainActor
    func closingPanelCancelsCommandCodeRefreshWithoutPublishingLateData() async {
        let appState = AppState()
        appState.commandCodeRateLimitEnabled = true
        var requestStarted = false
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchCommandCodeLive: {
                requestStarted = true
                try await Task.sleep(for: .seconds(30))
                return self.commandCodeSnapshot(
                    utilization: 99,
                    dataAsOf: Date(timeIntervalSince1970: 300)
                )
            }
        )

        let refresh = Task { @MainActor in await coordinator.refreshCommandCode() }
        while !requestStarted { await Task.yield() }
        #expect(appState.isCommandCodeRateLimitRefreshing)

        coordinator.panelVisibilityChanged(visible: false)
        await refresh.value

        #expect(!appState.isCommandCodeRateLimitRefreshing)
        #expect(appState.rateLimits.first(where: { $0.provider == .commandCode }) == nil)
    }
}

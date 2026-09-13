import Testing
@testable import VibeUsage

struct RuntimeDetectorTests {
    @Test
    func bunUsesExplicitLatestPackage() {
        #expect(RuntimeDetector.defaultPackageSpecifier == "@vibe-cafe/vibe-usage@latest")
        #expect(
            RuntimeDetector.arguments(runtimeName: "bun", command: ["sync"])
                == ["x", RuntimeDetector.packageSpecifier, "sync"]
        )
    }

    @Test
    func npxUsesExplicitLatestPackageForConfigCommands() {
        #expect(
            RuntimeDetector.arguments(runtimeName: "npx", command: ["config", "get", "apiKey"])
                == ["--yes", RuntimeDetector.packageSpecifier, "config", "get", "apiKey"]
        )
    }

    @Test
    func macAppIdentityUsesTheDisplayVersion() {
        #expect(AppConfig.cliIdentityEnvironment["VIBE_USAGE_SURFACE"] == "mac-app")
        #expect(AppConfig.cliIdentityEnvironment["VIBE_USAGE_SURFACE_VERSION"] == AppConfig.version)
    }
}

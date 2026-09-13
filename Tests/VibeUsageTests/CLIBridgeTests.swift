import Foundation
import Testing
@testable import VibeUsage

struct CLIBridgeTests {
    @Test
    func decodeRootsPreservesToolSpecificLists() throws {
        let roots = try CLIBridge.decodeRoots("""
        {
          "codex": ["/runtime/a", "/runtime/b"],
          "grok": ["/runtime/grok"],
          "antigravity": []
        }
        """)

        #expect(roots["codex"] == ["/runtime/a", "/runtime/b"])
        #expect(roots["grok"] == ["/runtime/grok"])
        #expect(roots["antigravity"] == [])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIBE_USAGE_CLI_PACKAGE"] != nil
                  && ProcessInfo.processInfo.environment["VIBE_USAGE_CONFIG_DIR"] != nil,
                  "需要隔离配置目录和本地 CLI 路径"))
    func configCommandsAgainstLocalCLI() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-usage-cli-bridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let layouts = [
            ("codex", "codex/sessions"),
            ("grok", "grok/sessions"),
            ("antigravity", "agy/.gemini/antigravity/conversations"),
        ]

        for (_, relativePath) in layouts {
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent(relativePath),
                withIntermediateDirectories: true
            )
        }

        for (source, relativePath) in layouts {
            let root = base.appendingPathComponent(relativePath.components(separatedBy: "/").first!).path
            try await CLIBridge.configAddRoot(source: source, path: root)
        }

        let roots = try await CLIBridge.configRoots()
        #expect(roots["codex"] == [base.appendingPathComponent("codex").path])
        #expect(roots["grok"] == [base.appendingPathComponent("grok").path])
        #expect(roots["antigravity"] == [base.appendingPathComponent("agy").path])

        try await CLIBridge.configRemoveRoot(
            source: "grok",
            path: base.appendingPathComponent("grok").path
        )
        let rootsAfterRemoval = try await CLIBridge.configRoots()
        #expect(rootsAfterRemoval["grok"] == nil)
    }
}

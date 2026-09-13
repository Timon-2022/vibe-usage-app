import Foundation
import Testing
@testable import VibeUsage

struct ConfigManagerTests {
    @Test
    func mergedConfigPreservesCLIFieldsWhileUpdatingAppValues() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "apiKey": "vbu_old",
            "apiUrl": "https://old.example",
            "hostname": "private-workstation",
            "uploadProject": false,
            "uploadHostname": false,
            "deviceId": "device-0011223344556677",
            "lastUploadProject": true,
            "futureCLIField": "keep-me",
        ])
        let config = VibeUsageConfig(
            apiKey: "vbu_new",
            apiUrl: "https://new.example",
            lastSync: nil,
            codexExtraHome: "/tmp/extra-codex"
        )

        let data = try ConfigManager.mergedConfigData(config, existingData: existing)
        let result = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(result["apiKey"] as? String == "vbu_new")
        #expect(result["apiUrl"] as? String == "https://new.example")
        #expect(result["codexExtraHome"] as? String == "/tmp/extra-codex")
        #expect(result["hostname"] as? String == "private-workstation")
        #expect(result["uploadProject"] as? Bool == false)
        #expect(result["uploadHostname"] as? Bool == false)
        #expect(result["deviceId"] as? String == "device-0011223344556677")
        #expect(result["lastUploadProject"] as? Bool == true)
        #expect(result["futureCLIField"] as? String == "keep-me")
    }
}

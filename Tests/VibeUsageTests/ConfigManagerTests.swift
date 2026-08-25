import XCTest
@testable import VibeUsage

final class ConfigManagerTests: XCTestCase {
    func testMergedConfigPreservesCLIFieldsWhileUpdatingAppValues() throws {
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
        let result = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(result["apiKey"] as? String, "vbu_new")
        XCTAssertEqual(result["apiUrl"] as? String, "https://new.example")
        XCTAssertEqual(result["codexExtraHome"] as? String, "/tmp/extra-codex")
        XCTAssertEqual(result["hostname"] as? String, "private-workstation")
        XCTAssertEqual(result["uploadProject"] as? Bool, false)
        XCTAssertEqual(result["uploadHostname"] as? Bool, false)
        XCTAssertEqual(result["deviceId"] as? String, "device-0011223344556677")
        XCTAssertEqual(result["lastUploadProject"] as? Bool, true)
        XCTAssertEqual(result["futureCLIField"] as? String, "keep-me")
    }
}

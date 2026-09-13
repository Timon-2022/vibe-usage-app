import Foundation
import Testing
@testable import VibeUsage

@MainActor
struct AppStateRateLimitSettingsTests {
    @Test
    func commandCodeDisplayPreferencePersistsAndCanBeToggled() {
        let defaults = UserDefaults.standard
        let key = "commandCodeRateLimitEnabled"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let state = AppState()
        state.commandCodeRateLimitEnabled = false
        #expect(defaults.object(forKey: key) as? Bool == false)

        state.commandCodeRateLimitEnabled = true
        #expect(defaults.object(forKey: key) as? Bool == true)
    }
}

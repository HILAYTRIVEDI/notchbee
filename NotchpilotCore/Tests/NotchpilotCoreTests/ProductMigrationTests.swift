import Foundation
import Testing
@testable import NotchpilotCore

struct ProductMigrationTests {
    @Test func migrationDropsLegacyEngineChoiceAndPreservesLaterChanges() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let models = root.appending(path: "Notchpilot/Models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try Data([1, 2]).write(to: models.appending(path: "model"))
        let old = ["engineChoice": "existing", "KeyboardShortcuts_pushToTalk": "shortcut"]
        try ProductMigration.run(defaults: defaults, legacy: old, support: root)
        #expect(defaults.object(forKey: "engineChoice") == nil)
        #expect(defaults.string(forKey: "KeyboardShortcuts_pushToTalk") == "shortcut")
        #expect(try Data(contentsOf: root.appending(path: "Notchbee/Models/model")) == Data([1, 2]))
        defaults.set("existing", forKey: "engineChoice")
        defaults.set("new shortcut", forKey: "KeyboardShortcuts_pushToTalk")
        try ProductMigration.run(defaults: defaults, legacy: old, support: root)
        #expect(defaults.object(forKey: "engineChoice") == nil)
        #expect(defaults.string(forKey: "KeyboardShortcuts_pushToTalk") == "new shortcut")
    }
}

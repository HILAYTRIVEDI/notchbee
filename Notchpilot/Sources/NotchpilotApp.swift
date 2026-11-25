import AppKit
import NotchpilotCore

@main
struct NotchpilotApp {
    static func main() {
        let app = NSApplication.shared
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            app.run()
            return
        }
        do {
            try ProductMigration.migrate()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t migrate your previous data"
            alert.runModal()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

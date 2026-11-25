import AppKit
import NotchpilotCore
import Sparkle

@MainActor
enum AppMaintenance {
    static let updates: SPUStandardUpdaterController = {
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil,
                                                       userDriverDelegate: nil)
        controller.updater.sendsSystemProfile = false
        controller.startUpdater()
        return controller
    }()
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
    }

    static func copyDiagnostics(connection: AgentConnection) {
        let status: String
        switch connection {
        case .connected: status = "Connected"
        case .disconnected: status = "Disconnected"
        case .engineStarting: status = "Starting"
        case .engineRestarting: status = "Restarting"
        case .failed, .engineFailed: status = "Failed"
        }
        // Provider and process log lines can contain arbitrary user data.
        let report = ["\(Product.name) \(version)", ProcessInfo.processInfo.operatingSystemVersionString,
                      "Built-in engine: \(status)"]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.joined(separator: "\n"), forType: .string)
    }

}

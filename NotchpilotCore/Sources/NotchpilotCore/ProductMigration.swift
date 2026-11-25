import Foundation

public enum ProductMigration {
    static let marker = "notchbeeMigrationV1"
    static let legacyDomain = "com.hilaytrivedi.Notchpilot"

    public static func migrate() throws {
        let defaults = UserDefaults.standard
        try run(defaults: defaults, legacy: defaults.persistentDomain(forName: legacyDomain) ?? [:],
                support: URL.applicationSupportDirectory)
    }

    static func run(defaults: UserDefaults, legacy: [String: Any], support: URL) throws {
        defaults.removeObject(forKey: "engineChoice")
        guard !defaults.bool(forKey: marker) else { return }
        let files = FileManager.default
        let source = support.appending(path: "Notchpilot")
        let destination = support.appending(path: Product.name)
        if files.fileExists(atPath: source.path) {
            try files.createDirectory(at: destination, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            for child in try files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                    where child.lastPathComponent != "engine.pid" {
                try copyMissing(child, to: destination.appending(path: child.lastPathComponent))
            }
        }
        for (key, value) in legacy where key != "engineChoice" && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: marker)
    }

    private static func copyMissing(_ source: URL, to destination: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            guard try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isSymbolicLink != true,
                  try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { return }
            for child in try files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copyMissing(child, to: destination.appending(path: child.lastPathComponent))
            }
            return
        }
        let staging = destination.deletingLastPathComponent().appending(path: ".migration-" + UUID().uuidString)
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: source, to: staging)
        try files.moveItem(at: staging, to: destination)
    }
}

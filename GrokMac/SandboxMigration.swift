import Foundation

/// The app used to run in App Sandbox, so its data lived in ~/Library/Containers/app.grok.mac.
/// Copy conversations, videos and preferences out once so nothing is lost after the sandbox was turned off.
enum SandboxMigration {
    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "grok.migratedFromSandbox") else { return }
        defer { defaults.set(true, forKey: "grok.migratedFromSandbox") }
        let id = Bundle.main.bundleIdentifier ?? "app.grok.mac"
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let container = home.appendingPathComponent("Library/Containers/\(id)/Data/Library", isDirectory: true)
        guard fm.fileExists(atPath: container.path) else { return }

        let oldData = container.appendingPathComponent("Application Support/GrokMac", isDirectory: true)
        let newData = home.appendingPathComponent("Library/Application Support/GrokMac", isDirectory: true)
        if fm.fileExists(atPath: oldData.path), !fm.fileExists(atPath: newData.appendingPathComponent("sessions.json").path) {
            try? fm.createDirectory(at: newData.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: newData.path) {
                for name in (try? fm.contentsOfDirectory(atPath: oldData.path)) ?? [] {
                    try? fm.copyItem(at: oldData.appendingPathComponent(name), to: newData.appendingPathComponent(name))
                }
            } else {
                try? fm.copyItem(at: oldData, to: newData)
            }
        }

        let plist = container.appendingPathComponent("Preferences/\(id).plist")
        if let old = NSDictionary(contentsOf: plist) as? [String: Any] {
            for (key, value) in old where key.hasPrefix("grok.") && defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
    }
}

import AppKit

@MainActor
enum LoginSession {
    static func start() {
        guard let url = URL(string: "https://accounts.x.ai/sign-in") else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(url, configuration: config) { _, error in
            if error != nil {
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

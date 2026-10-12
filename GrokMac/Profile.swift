import AppKit
import Foundation

/// The signed-in xAI account's name, email and picture (Google photo when signed in with Google),
/// read from the OIDC userinfo endpoint https://auth.x.ai/oauth2/userinfo with the stored access
/// token. The login already asks for the "profile" and "email" scopes, so no re-login is needed.
/// The picture is cached on disk so the avatar shows instantly and offline.
struct AccountProfile: Codable, Equatable {
    var name: String?
    var email: String?
    var picture: String?

    var initials: String {
        let source = (name?.isEmpty == false ? name : email) ?? ""
        let words = source.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." })
        if let first = words.first?.first, source.unicodeScalars.first.map({ $0.value > 0x2E7F }) == true {
            return String(first)
        }
        return words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GrokMac", isDirectory: true)
    }
    private static var infoURL: URL { folder.appendingPathComponent("profile.json") }
    static var imageURL: URL { folder.appendingPathComponent("avatar-image") }

    static func cached() -> AccountProfile? {
        guard let data = try? Data(contentsOf: infoURL) else { return nil }
        return try? JSONDecoder().decode(AccountProfile.self, from: data)
    }

    static func cachedImage() -> NSImage? {
        NSImage(contentsOf: imageURL)
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: infoURL)
        try? FileManager.default.removeItem(at: imageURL)
    }

    /// Fetches userinfo and the picture. Returns nil on any failure; never touches the login.
    static func refresh(token: String) async -> (AccountProfile, NSImage?)? {
        guard !token.isEmpty else { return nil }
        var request = URLRequest(url: URL(string: "https://auth.x.ai/oauth2/userinfo")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let profile = AccountProfile(
            name: json["name"] as? String ?? json["given_name"] as? String,
            email: json["email"] as? String,
            picture: json["picture"] as? String
        )
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let encoded = try? JSONEncoder().encode(profile) { try? encoded.write(to: infoURL, options: .atomic) }
        var image: NSImage?
        if let raw = profile.picture, let url = URL(string: raw),
           let (bytes, imageResponse) = try? await URLSession.shared.data(from: url),
           (imageResponse as? HTTPURLResponse)?.statusCode == 200,
           let decoded = NSImage(data: bytes) {
            try? bytes.write(to: imageURL, options: .atomic)
            image = decoded
        }
        return (profile, image ?? cachedImage())
    }
}

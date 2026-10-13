import Foundation
import Security

/// The xAI token lives in the login keychain (service app.grok.mac, account xai-api-key). The OAuth
/// refresh token and the access token's expiry sit next to it (accounts xai-refresh-token and
/// xai-token-expires-at) with the same ACL, so a rebuild never prompts for them either.
///
/// Items made by earlier ad-hoc builds carry an ACL bound to that build's cdhash, so every rebuild
/// failed the check and macOS asked again, once per read. The token is now read once per launch and
/// cached, and the item is rewritten once with an ACL that does not name a specific binary. Access
/// stays limited by the keychain partition list, which SecItemAdd sets to this app's team ID.
enum KeychainStore {
    private static let service = "app.grok.mac"
    private static let account = "xai-api-key"
    private static let migratedKey = "grok.keychain.aclV2"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: String?

    static func load() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let text = read()
        cached = text
        if !text.isEmpty, !UserDefaults.standard.bool(forKey: migratedKey) {
            write(text)
        }
        return text
    }

    static func save(_ raw: String) {
        lock.lock()
        defer { lock.unlock() }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        cached = text
        write(text)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static let refreshAccount = "xai-refresh-token"
    private static let expiryAccount = "xai-token-expires-at"
    nonisolated(unsafe) private static var cachedRefresh: String?
    nonisolated(unsafe) private static var cachedExpiry: Date??

    static func loadRefresh() -> String {
        lock.lock(); defer { lock.unlock() }
        if let cachedRefresh { return cachedRefresh }
        let text = read(refreshAccount)
        cachedRefresh = text
        return text
    }

    /// When the access token stops working; nil when unknown (tokens saved by older builds).
    static func loadExpiry() -> Date? {
        lock.lock(); defer { lock.unlock() }
        if let cachedExpiry { return cachedExpiry }
        let value = TimeInterval(read(expiryAccount)).map { Date(timeIntervalSince1970: $0) }
        cachedExpiry = .some(value)
        return value
    }

    /// Saves a full token set from the OAuth token endpoint. An empty refresh keeps the old one
    /// (refresh responses may omit it); a nil expiry clears it.
    static func saveTokens(access: String, refresh: String, expiresAt: Date?) {
        lock.lock(); defer { lock.unlock() }
        cached = access
        write(access)
        if !refresh.isEmpty { cachedRefresh = refresh; write(refresh, account: refreshAccount) }
        cachedExpiry = .some(expiresAt)
        write(expiresAt.map { String(Int($0.timeIntervalSince1970)) } ?? "", account: expiryAccount)
    }

    /// Clears the access token, refresh token and expiry (sign out, or a refresh the server refused).
    static func clearAll() {
        lock.lock(); defer { lock.unlock() }
        cached = ""; cachedRefresh = ""; cachedExpiry = .some(nil)
        write("")
        write("", account: refreshAccount)
        write("", account: expiryAccount)
    }

    private static func read(_ account: String = account) -> String {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func write(_ text: String, account: String = account) {
        let primary = account == Self.account
        SecItemDelete(baseQuery(account) as CFDictionary)
        guard !text.isEmpty, let data = text.data(using: .utf8) else {
            if primary { UserDefaults.standard.removeObject(forKey: migratedKey) }
            return
        }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = service
        if let access = openAccess() {
            add[kSecAttrAccess as String] = access
        }
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess, primary {
            UserDefaults.standard.set(true, forKey: migratedKey)
        }
    }

    /// A legacy keychain access object whose decrypt ACL trusts no particular binary (nil app list),
    /// so a rebuilt app with a new cdhash is not prompted again.
    private static func openAccess() -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate(service as CFString, nil, &access) == errSecSuccess, let access else { return nil }
        guard let acls = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL] else { return access }
        for acl in acls {
            SecACLSetContents(acl, nil, service as CFString, SecKeychainPromptSelector())
        }
        return access
    }
}

/// Keeps the xAI access token fresh with the stored OAuth refresh token.
@MainActor
enum TokenStore {
    static let signedOutNotification = Notification.Name("grok.signedOut")
    static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    /// Refresh this long before the token's stated expiry.
    private static let margin: TimeInterval = 300
    private static var inFlight: Task<String?, Never>?

    /// A token that is not about to expire: refreshes first when it is (or when the debug flag
    /// `grok.debug.forceRefresh` is set). Returns "" when signed out.
    static func valid() async -> String {
        let current = KeychainStore.load()
        guard !current.isEmpty else { return "" }
        let forced = UserDefaults.standard.bool(forKey: "grok.debug.forceRefresh")
        if forced { UserDefaults.standard.removeObject(forKey: "grok.debug.forceRefresh") }
        if forced || (KeychainStore.loadExpiry().map { $0.timeIntervalSinceNow < margin } ?? false) {
            return await refresh() ?? ""
        }
        return current
    }

    /// One refresh at a time. On a refused or missing refresh token the user is signed out for real.
    @discardableResult
    static func refresh() async -> String? {
        if let inFlight { return await inFlight.value }
        let task = Task<String?, Never> { await performRefresh() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    private static func performRefresh() async -> String? {
        let refresh = KeychainStore.loadRefresh()
        guard !refresh.isEmpty else {
            NSLog("GrokMac token: no refresh token; signing out")
            signOut()
            return nil
        }
        var request = URLRequest(url: URL(string: "https://auth.x.ai/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = Data(form(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID]).utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let access = json?["access_token"] as? String ?? ""
            guard status == 200, !access.isEmpty else {
                NSLog("GrokMac token: refresh refused (HTTP %d); signing out", status)
                // 4xx means the refresh token is no good; 5xx or no network keeps the session for a retry.
                if (400..<500).contains(status) { signOut() }
                return nil
            }
            store(json ?? [:])
            NSLog("GrokMac token: refreshed, expires %@", String(describing: KeychainStore.loadExpiry()))
            return access
        } catch {
            NSLog("GrokMac token: refresh failed: %@", error.localizedDescription)
            return nil
        }
    }

    /// Saves an OAuth token response (authorization_code or refresh_token grant).
    static func store(_ json: [String: Any]) {
        let access = json["access_token"] as? String ?? ""
        let refresh = json["refresh_token"] as? String ?? ""
        let expiry = (json["expires_in"] as? NSNumber).map { Date().addingTimeInterval($0.doubleValue) }
        KeychainStore.saveTokens(access: access, refresh: refresh, expiresAt: expiry)
    }

    private static func signOut() {
        KeychainStore.clearAll()
        NotificationCenter.default.post(name: signedOutNotification, object: nil)
    }

    static func form(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }.joined(separator: "&")
    }
}

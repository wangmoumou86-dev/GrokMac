import Foundation
import Security

/// The xAI token lives in the login keychain (service app.grok.mac, account xai-api-key).
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

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read() -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func write(_ text: String) {
        SecItemDelete(baseQuery as CFDictionary)
        guard !text.isEmpty, let data = text.data(using: .utf8) else {
            UserDefaults.standard.removeObject(forKey: migratedKey)
            return
        }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = service
        if let access = openAccess() {
            add[kSecAttrAccess as String] = access
        }
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess {
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

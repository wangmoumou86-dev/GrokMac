import AppKit
import Foundation

enum ProjectStore {
    private static let key = "grok.project.bookmark"

    static func save(_ url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: key)
    }

    static func url() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        if stale, let fresh = try? resolved.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: key)
        }
        return resolved
    }

    static func label() -> String {
        url()?.path ?? "还没有选择"
    }
}

struct ProjectAccess {
    let root: URL
    let started: Bool

    static func open() -> ProjectAccess? {
        guard let root = ProjectStore.url() else { return nil }
        return ProjectAccess(root: root, started: root.startAccessingSecurityScopedResource())
    }

    func close() {
        if started { root.stopAccessingSecurityScopedResource() }
    }
}

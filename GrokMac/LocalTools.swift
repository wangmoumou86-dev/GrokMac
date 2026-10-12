import Foundation

enum LocalTools {
    static func run(name: String, arguments: String, root: URL, key: String, access: String = "workspace") async -> (String, Bool) {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        let str = { (key: String) -> String in args[key] as? String ?? "" }
        let writes = ["write_file", "edit_file", "apply_patch", "todo_write", "undo"]
        if access == "read-only", writes.contains(name) {
            return ("只读沙箱，这次没有批准写出。", false)
        }
        switch name {
        case "bash":
            return await bash(root: root, command: str("command"), access: access)
        case "read_file":
            let offset = (args["offset"] as? NSNumber)?.intValue ?? 1
            let limit = (args["limit"] as? NSNumber)?.intValue ?? 200
            return readFile(root: root, path: str("path"), offset: offset, limit: limit)
        case "write_file":
            return writeFile(root: root, path: str("path"), content: str("content"))
        case "edit_file":
            return editFile(root: root, path: str("path"), old: str("old_string"), new: str("new_string"))
        case "apply_patch":
            return patch(root: root, text: str("patch"))
        case "glob":
            return glob(root: root, pattern: str("pattern"))
        case "grep":
            return grep(root: root, pattern: str("pattern"), scope: str("path"))
        case "codebase_search":
            return search(root: root, query: str("query"))
        case "web_search":
            return await webSearch(key: key, query: str("query"))
        case "web_fetch":
            return await webFetch(str("url"))
        case "todo_write":
            return todo(root: root, raw: args["todos"])
        case "generate_image":
            return await image(key: key, prompt: str("prompt"))
        case "undo":
            return undo(root: root)
        case "run_tests":
            return await bash(root: root, command: testCommand(root: root, requested: str("command")), access: access)
        case "open_pr":
            let title = str("title").replacingOccurrences(of: "\"", with: "")
            let body = str("body").replacingOccurrences(of: "\"", with: "")
            return await bash(root: root, command: "git status --short && gh pr create --title \"\(title)\" --body \"\(body)\"", access: access)
        default:
            return ("没有这个工具：\(name)", false)
        }
    }

    /// Relative paths resolve against the working folder; absolute and ~ paths may point anywhere.
    /// Scope is enforced before a tool runs, in GrokClient.escalation: writes outside the working folder
    /// and sensitive reads wait for the user's approval, so an approved write to /tmp (a symlink to
    /// /private/tmp) or any other folder actually goes through.
    static func resolve(_ root: URL, _ rel: String) throws -> URL {
        var cleaned = rel.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "\0", with: "")
        if cleaned == "~" || cleaned.hasPrefix("~/") { cleaned = NSHomeDirectory() + cleaned.dropFirst() }
        let base = root.standardizedFileURL
        return URL(fileURLWithPath: cleaned.isEmpty ? "." : cleaned, relativeTo: base).standardizedFileURL
    }

    private static func readFile(root: URL, path: String, offset: Int, limit: Int) -> (String, Bool) {
        do {
            let url = try resolve(root, path)
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let start = max(0, offset - 1)
            let count = min(400, max(1, limit))
            return (clip(lines.dropFirst(start).prefix(count).joined(separator: "\n")), true)
        } catch {
            return (error.localizedDescription, false)
        }
    }

    private static func writeFile(root: URL, path: String, content: String) -> (String, Bool) {
        do {
            let url = try resolve(root, path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            snapshot(root: root, path: path)
            try String(content.prefix(200_000)).write(to: url, atomically: true, encoding: .utf8)
            return ("已写入 \(path)", true)
        } catch {
            return (error.localizedDescription, false)
        }
    }

    private static func editFile(root: URL, path: String, old: String, new: String) -> (String, Bool) {
        do {
            let url = try resolve(root, path)
            let text = try String(contentsOf: url, encoding: .utf8)
            let hits = text.components(separatedBy: old).count - 1
            guard !old.isEmpty, hits == 1 else { return ("需要恰好一处匹配，现在是 \(hits) 处。", false) }
            snapshot(root: root, path: path)
            try text.replacingOccurrences(of: old, with: new).write(to: url, atomically: true, encoding: .utf8)
            return ("已修改 \(path)", true)
        } catch {
            return (error.localizedDescription, false)
        }
    }

    private static func glob(root: URL, pattern: String) -> (String, Bool) {
        let files = walk(root)
        let needle = pattern.lowercased()
        let hits = files.filter { $0.lowercased().contains(needle) }
        return (clip(hits.joined(separator: "\n").isEmpty ? "没有匹配的文件。" : hits.joined(separator: "\n")), true)
    }

    private static func grep(root: URL, pattern: String, scope: String) -> (String, Bool) {
        guard !pattern.isEmpty else { return ("缺少要搜的文字。", false) }
        var hits: [String] = []
        for file in walk(root) where scope.isEmpty || file.hasPrefix(scope) {
            guard hits.count < 80, let url = try? resolve(root, file), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let regex = try? NSRegularExpression(pattern: pattern)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let row = String(line)
                let matched = regex?.firstMatch(in: row, range: NSRange(row.startIndex..., in: row)) != nil || row.contains(pattern)
                if matched {
                    hits.append("\(file):\(index + 1):\(row)")
                    if hits.count >= 80 { break }
                }
            }
        }
        return (clip(hits.isEmpty ? "没有匹配。" : hits.joined(separator: "\n")), true)
    }

    private static func todo(root: URL, raw: Any?) -> (String, Bool) {
        let todos = raw as? [[String: Any]] ?? []
        do {
            let url = try resolve(root, ".grok/todos.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: todos, options: [.prettyPrinted])
            try data.write(to: url)
            return ("已更新 \(todos.count) 条任务。", true)
        } catch {
            return (error.localizedDescription, false)
        }
    }

    /// One worktree per conversation: the same session id maps to the same folder and branch, so later
    /// messages keep building on the earlier changes instead of starting a fresh worktree each time.
    static func makeWorktree(root: URL, session: UUID) -> URL? {
        let id = String(session.uuidString.prefix(8))
        let dest = root.appendingPathComponent(".grok/worktrees/\(id)", isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.appendingPathComponent(".git").path) { return dest }
        // New branch first; if the branch survived a removed folder, check it out again instead.
        for args in [["worktree", "add", "-b", "grok/\(id)", dest.path], ["worktree", "add", dest.path, "grok/\(id)"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = root
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return nil
            }
            if process.terminationStatus == 0 { return dest }
        }
        return nil
    }

    private static func bash(root: URL, command: String, access: String) async -> (String, Bool) {
        let result = await shell(root: root, command: command, access: access)
        // A sandboxed app may not be allowed to apply a second sandbox-exec profile. The command then
        // runs with plain /bin/bash, still confined by the app's own App Sandbox, and the card says so.
        if access != "full", result.0.contains("sandbox_apply") {
            let retry = await shell(root: root, command: command, access: "full")
            return ("（sandbox-exec 在应用沙盒里不可用，这条命令只受 App Sandbox 限制）\n" + retry.0, retry.1)
        }
        return result
    }

    private static func shell(root: URL, command: String, access: String) async -> (String, Bool) {
        let limited = String(command.prefix(4_000))
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                if access != "full", FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") {
                    let network = access == "workspace-net" ? "(allow network*)" : "(deny network*)"
                    let files = access == "read-only"
                        ? "(allow file-read*) (deny file-write*)"
                        : """
                        (allow file-read*)
                        (allow file-write* (subpath "\(root.path)") (subpath "\(NSHomeDirectory())") (subpath "/private/tmp") (subpath "/private/var/folders") (literal "/dev/null"))
                        """
                    let profile = """
                    (version 1)
                    (deny default)
                    (allow process*)
                    \(files)
                    \(network)
                    """
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
                    process.arguments = ["-p", profile, "/bin/bash", "-lc", limited]
                } else {
                    process.executableURL = URL(fileURLWithPath: "/bin/bash")
                    process.arguments = ["-lc", limited]
                }
                process.currentDirectoryURL = root
                var env = ProcessInfo.processInfo.environment
                for name in ["XAI_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY"] {
                    env.removeValue(forKey: name)
                }
                process.environment = env
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (error.localizedDescription, false))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                    if process.isRunning { process.terminate() }
                }
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (clip("exit \(process.terminationStatus)\n\(text)"), true))
            }
        }
    }

    private static func webSearch(key: String, query: String) async -> (String, Bool) {
        let sets: [[String: String]] = [["web_search": "1", "x_search": "1"], ["web_search": "1"]]
        for set in sets {
            var tools: [[String: String]] = [["type": "web_search"]]
            if set["x_search"] != nil { tools.insert(["type": "x_search"], at: 0) }
            do {
                let data = try await post(
                    key: key,
                    url: "https://api.x.ai/v1/responses",
                    body: ["model": "grok-4.7", "input": [["role": "user", "content": String(query.prefix(500))]], "tools": tools]
                )
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if let text = json?["output_text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return (clip(text), true)
                }
                var parts: [String] = []
                for item in json?["output"] as? [[String: Any]] ?? [] {
                    if let text = item["text"] as? String { parts.append(text) }
                    for piece in item["content"] as? [[String: Any]] ?? [] {
                        if let text = piece["text"] as? String { parts.append(text) }
                    }
                }
                if !parts.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return (clip(parts.joined(separator: "\n")), true)
                }
            } catch {
                continue
            }
        }
        return ("没有搜到结果。", false)
    }

    private static func webFetch(_ raw: String) async -> (String, Bool) {
        guard let url = URL(string: raw), let host = url.host?.lowercased(), url.scheme == "http" || url.scheme == "https" else {
            return ("只打开 http 或 https。", false)
        }
        if host == "localhost" || host.hasSuffix(".local") || host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") || host == "0.0.0.0" {
            return ("这个地址不能打开。", false)
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let html = String(data: data, encoding: .utf8) ?? ""
            let text = html
                .replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            return (clip("\(status) \(url.absoluteString)\n\(text)"), true)
        } catch {
            return (error.localizedDescription, false)
        }
    }

    private static func image(key: String, prompt: String) async -> (String, Bool) {
        for model in ["grok-imagine-image-2.0", "grok-imagine-image"] {
            do {
                let data = try await post(
                    key: key,
                    url: "https://api.x.ai/v1/images/generations",
                    body: ["model": model, "prompt": String(prompt.prefix(2000)), "n": 1]
                )
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let rows = json?["data"] as? [[String: Any]] ?? []
                if let url = rows.first?["url"] as? String { return (url, true) }
            } catch {
                continue
            }
        }
        return ("没有生成图片。", false)
    }

    private static func post(key: String, url: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ToolFailure("请求失败（\(status)）。") }
        return data
    }

    private static func walk(_ root: URL) -> [String] {
        var out: [String] = []
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        for case let url as URL in enumerator {
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if rel == ".git" || rel == "node_modules" || rel.hasPrefix(".git/") || rel.hasPrefix("node_modules/") {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true { out.append(rel) }
            if out.count >= 200 { break }
        }
        return out
    }

    private static func clip(_ text: String) -> String {
        text.count > 8_000 ? String(text.prefix(8_000)) + "\n…截断" : text
    }

    private static func snapshot(root: URL, path: String) {
        let file = try? resolve(root, path)
        let content = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let log = root.appendingPathComponent(".grok/undo.json")
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        var stack = (try? JSONSerialization.jsonObject(with: Data(contentsOf: log))) as? [[String: Any]] ?? []
        stack.append(["path": path, "content": (content ?? NSNull()) as Any])
        if stack.count > 30 { stack.removeFirst(stack.count - 30) }
        if let data = try? JSONSerialization.data(withJSONObject: stack) {
            try? data.write(to: log)
        }
    }

    private static func undo(root: URL) -> (String, Bool) {
        let log = root.appendingPathComponent(".grok/undo.json")
        guard var stack = (try? JSONSerialization.jsonObject(with: Data(contentsOf: log))) as? [[String: Any]], let last = stack.popLast() else {
            return ("没有可撤销的修改。", false)
        }
        if let data = try? JSONSerialization.data(withJSONObject: stack) { try? data.write(to: log) }
        let rel = last["path"] as? String ?? ""
        guard let file = try? resolve(root, rel) else { return ("路径无效。", false) }
        if last["content"] is NSNull || last["content"] == nil {
            try? FileManager.default.removeItem(at: file)
            return ("已撤销新建 \(rel)", true)
        }
        let content = last["content"] as? String ?? ""
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? content.write(to: file, atomically: true, encoding: .utf8)
        return ("已撤销 \(rel)", true)
    }

    private static func search(root: URL, query: String) -> (String, Bool) {
        let terms = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
        guard !terms.isEmpty else { return ("没有可搜的词。", false) }
        var ranked: [(String, Int, [String])] = []
        for file in walk(root) {
            guard let url = try? resolve(root, file), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lower = text.lowercased()
            let score = terms.reduce(0) { $0 + lower.components(separatedBy: $1).count - 1 }
            if score == 0 { continue }
            let lines = text.split(separator: "\n").map(String.init).filter { line in terms.contains { line.lowercased().contains($0) } }
            ranked.append((file, score, Array(lines.prefix(6))))
        }
        ranked.sort { $0.1 > $1.1 }
        let body = ranked.prefix(5).map { "\($0.0)\n\($0.2.joined(separator: "\n"))" }.joined(separator: "\n\n")
        return (clip(body.isEmpty ? "没有匹配。" : body), true)
    }

    private static func patch(root: URL, text: String) -> (String, Bool) {
        var notes: [String] = []
        let lines = text.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let rel = line.dropPrefix("*** Add File: ") {
                i += 1
                var buf: [String] = []
                while i < lines.count, !lines[i].hasPrefix("*** ") {
                    if lines[i].hasPrefix("+") { buf.append(String(lines[i].dropFirst())) }
                    i += 1
                }
                snapshot(root: root, path: rel)
                if let file = try? resolve(root, rel) {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? buf.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
                    notes.append("已添加 \(rel)")
                }
                continue
            }
            if let rel = line.dropPrefix("*** Delete File: ") {
                snapshot(root: root, path: rel)
                if let file = try? resolve(root, rel) { try? FileManager.default.removeItem(at: file) }
                notes.append("已删除 \(rel)")
                i += 1
                continue
            }
            if let rel = line.dropPrefix("*** Update File: ") {
                guard var current = (try? resolve(root, rel)).flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else {
                    return ("读不到 \(rel)", false)
                }
                snapshot(root: root, path: rel)
                i += 1
                var oldLines: [String] = []
                var newLines: [String] = []
                func flush() -> String? {
                    guard !oldLines.isEmpty || !newLines.isEmpty else { return nil }
                    let old = oldLines.joined(separator: "\n")
                    let hits = old.isEmpty ? 0 : current.components(separatedBy: old).count - 1
                    if old.isEmpty || hits != 1 { return "\(rel) 的补丁对不上（\(hits) 处）。" }
                    current = current.replacingOccurrences(of: old, with: newLines.joined(separator: "\n"))
                    oldLines = []
                    newLines = []
                    return nil
                }
                while i < lines.count, !lines[i].hasPrefix("*** ") {
                    let row = lines[i]
                    if row.hasPrefix("@@") {
                        if let error = flush() { return (error, false) }
                    } else if row.hasPrefix("-") {
                        oldLines.append(String(row.dropFirst()))
                    } else if row.hasPrefix("+") {
                        newLines.append(String(row.dropFirst()))
                    } else if row.hasPrefix(" ") {
                        oldLines.append(String(row.dropFirst()))
                        newLines.append(String(row.dropFirst()))
                    }
                    i += 1
                }
                if let error = flush() { return (error, false) }
                if let file = try? resolve(root, rel) {
                    try? current.write(to: file, atomically: true, encoding: .utf8)
                }
                notes.append("已打补丁 \(rel)")
                continue
            }
            i += 1
        }
        return (notes.isEmpty ? "补丁里没有文件。" : notes.joined(separator: "\n"), !notes.isEmpty)
    }

    private static func testCommand(root: URL, requested: String) -> String {
        if !requested.trimmingCharacters(in: .whitespaces).isEmpty { return String(requested.prefix(300)) }
        let exists = { (name: String) in FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }
        if exists("package.json") { return "npm test" }
        if exists("Package.swift") { return "swift test" }
        if exists("pyproject.toml") || exists("pytest.ini") { return "pytest" }
        if exists("go.mod") { return "go test ./..." }
        return "echo 没有认出测试命令"
    }

    static func projectBrief(_ root: URL) -> String {
        var chunks: [String] = []
        for name in ["AGENTS.md", "CLAUDE.md", "README.md"] {
            let url = root.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            chunks.append("# \(name)\n\(text.prefix(2500))")
        }
        return String(chunks.joined(separator: "\n\n").prefix(6000))
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}

private struct ToolFailure: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

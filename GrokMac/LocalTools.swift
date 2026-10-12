import Foundation

enum LocalTools {
    static func run(name: String, arguments: String, root: URL, key: String) async -> (String, Bool) {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        let str = { (key: String) -> String in args[key] as? String ?? "" }
        switch name {
        case "bash":
            return await bash(root: root, command: str("command"))
        case "read_file":
            let offset = (args["offset"] as? NSNumber)?.intValue ?? 1
            let limit = (args["limit"] as? NSNumber)?.intValue ?? 200
            return readFile(root: root, path: str("path"), offset: offset, limit: limit)
        case "write_file":
            return writeFile(root: root, path: str("path"), content: str("content"))
        case "edit_file":
            return editFile(root: root, path: str("path"), old: str("old_string"), new: str("new_string"))
        case "glob":
            return glob(root: root, pattern: str("pattern"))
        case "grep":
            return grep(root: root, pattern: str("pattern"), scope: str("path"))
        case "web_search":
            return await webSearch(key: key, query: str("query"))
        case "web_fetch":
            return await webFetch(str("url"))
        case "todo_write":
            return todo(root: root, raw: args["todos"])
        case "generate_image":
            return await image(key: key, prompt: str("prompt"))
        default:
            return ("没有这个工具：\(name)", false)
        }
    }

    private static func resolve(_ root: URL, _ rel: String) throws -> URL {
        let cleaned = rel.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "\0", with: "")
        let base = root.standardizedFileURL
        let target = URL(fileURLWithPath: cleaned.isEmpty ? "." : cleaned, relativeTo: base).standardizedFileURL
        let rootPath = base.path
        let path = target.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else {
            throw ToolFailure("只能访问这个工程里的文件。")
        }
        if FileManager.default.fileExists(atPath: path) {
            let real = target.resolvingSymlinksInPath().path
            guard real == rootPath || real.hasPrefix(rootPath + "/") else {
                throw ToolFailure("只能访问这个工程里的文件。")
            }
        }
        return target
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
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where line.contains(pattern) {
                hits.append("\(file):\(index + 1):\(line)")
                if hits.count >= 80 { break }
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

    private static func bash(root: URL, command: String) async -> (String, Bool) {
        let limited = String(command.prefix(4_000))
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-lc", limited]
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
}

private struct ToolFailure: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

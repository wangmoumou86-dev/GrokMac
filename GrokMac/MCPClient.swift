import Foundation
import Observation

/// One configured MCP server, stored in ~/Library/Application Support/GrokMac/mcp.json
/// using the same `mcpServers` shape as Claude Desktop / Cursor.
struct MCPServerConfig: Identifiable, Equatable {
    var name: String
    var command: String = ""
    var args: [String] = []
    var env: [String: String] = [:]
    var url: String = ""
    var headers: [String: String] = [:]
    var enabled = true
    var alwaysAllow = false
    var id: String { name }
    var isHTTP: Bool { !url.isEmpty }
}

struct MCPTool {
    var server: String
    var name: String
    var description: String
    var schema: [String: Any]
    var readOnly: Bool
    var fullName: String { MCPManager.qualified(server, name) }
}

enum MCPError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// A live connection to one server: stdio (newline-delimited JSON-RPC) or streamable HTTP.
/// Spec: https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
final class MCPConnection: @unchecked Sendable {
    let config: MCPServerConfig
    private let lock = NSLock()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var sessionID: String?
    private(set) var stderrTail = ""

    init(config: MCPServerConfig) { self.config = config }

    func start() async throws {
        if !config.isHTTP { try launch() }
        _ = try await request("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "GrokMac", "version": "1.0"],
        ], timeout: 60)
        try await notify("notifications/initialized")
    }

    func listTools() async throws -> [MCPTool] {
        var tools: [MCPTool] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let result = try await request("tools/list", params, timeout: 30)
            for raw in result["tools"] as? [[String: Any]] ?? [] {
                guard let name = raw["name"] as? String else { continue }
                let hints = raw["annotations"] as? [String: Any] ?? [:]
                tools.append(MCPTool(
                    server: config.name, name: name,
                    description: (raw["description"] as? String) ?? "",
                    schema: MCPConnection.sanitize(raw["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [:] as [String: Any]]) as? [String: Any] ?? [:],
                    readOnly: hints["readOnlyHint"] as? Bool ?? false))
            }
            cursor = result["nextCursor"] as? String
        } while cursor != nil && !(cursor ?? "").isEmpty
        return tools
    }

    /// Drops JSON-schema `format` values the model API does not know (Rust servers emit uint, uint64, double…).
    static func sanitize(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                if k == "format", let f = v as? String, !["date-time", "date", "time", "email", "uri", "uuid"].contains(f) { continue }
                out[k] = sanitize(v)
            }
            return out
        }
        if let list = value as? [Any] { return list.map(sanitize) }
        return value
    }

    func call(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
        try await request("tools/call", ["name": name, "arguments": arguments], timeout: 120)
    }

    func stop() {
        lock.lock()
        let pending = waiting
        waiting = [:]
        lock.unlock()
        for (_, waiter) in pending { waiter.resume(throwing: MCPError.message(tr("连接已关闭。", "Connection closed."))) }
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    // MARK: stdio

    private func launch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [config.command] + config.args
        var env = ProcessInfo.processInfo.environment
        for name in ["XAI_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY"] { env.removeValue(forKey: name) }
        // Apps started from Finder get a minimal PATH; add the usual places node/npx/uvx/python live.
        let home = NSHomeDirectory()
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin", "\(home)/.bun/bin"]
        env["PATH"] = (extra + [(env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")]).joined(separator: ":")
        for (k, v) in config.env { env[k] = v }
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.receive(data)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let self else { return }
            self.lock.lock()
            self.stderrTail = String((self.stderrTail + (String(data: data, encoding: .utf8) ?? "")).suffix(600))
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let pending = self.waiting
            self.waiting = [:]
            let tail = self.stderrTail
            self.lock.unlock()
            for (_, waiter) in pending { waiter.resume(throwing: MCPError.message(tr("服务器进程退出了。\(tail.suffix(200))", "The server process exited. \(tail.suffix(200))"))) }
        }
        do { try process.run() } catch { throw MCPError.message(tr("启动失败：\(error.localizedDescription)", "Failed to start: \(error.localizedDescription)")) }
        self.process = process
        stdin = input.fileHandleForWriting
    }

    private func receive(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var messages: [[String: Any]] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { messages.append(json) }
        }
        lock.unlock()
        messages.forEach(deliver)
    }

    private func deliver(_ message: [String: Any]) {
        guard let id = (message["id"] as? Int) ?? (message["id"] as? NSNumber)?.intValue else {
            return
        }
        if message["method"] != nil {
            // Server-to-client request (ping, roots, sampling): answer so it does not hang.
            let reply: [String: Any] = message["method"] as? String == "ping"
                ? ["jsonrpc": "2.0", "id": id, "result": [:] as [String: Any]]
                : ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Not supported by GrokMac"]]
            try? write(reply)
            return
        }
        lock.lock()
        let waiter = waiting.removeValue(forKey: id)
        lock.unlock()
        if let error = message["error"] as? [String: Any] {
            waiter?.resume(throwing: MCPError.message((error["message"] as? String) ?? tr("MCP 错误", "MCP error")))
        } else {
            waiter?.resume(returning: message["result"] as? [String: Any] ?? [:])
        }
    }

    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        guard let stdin else { throw MCPError.message(tr("服务器没有运行。", "The server isn't running.")) }
        try stdin.write(contentsOf: data)
    }

    // MARK: JSON-RPC

    private func notify(_ method: String) async throws {
        let message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if config.isHTTP { _ = try await post(message, expectID: nil) } else { try write(message) }
    }

    private func request(_ method: String, _ params: [String: Any], timeout: Double) async throws -> [String: Any] {
        let id = allocateID()
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        if config.isHTTP {
            guard let reply = try await post(message, expectID: id) else { throw MCPError.message(tr("服务器没有返回结果。", "The server returned no result.")) }
            if let error = reply["error"] as? [String: Any] { throw MCPError.message((error["message"] as? String) ?? tr("MCP 错误", "MCP error")) }
            return reply["result"] as? [String: Any] ?? [:]
        }
        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.park(id, continuation)
                    do { try self.write(message) } catch {
                        self.take(id)?.resume(throwing: error)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                self.take(id)?.resume(throwing: MCPError.message(tr("\(method) 超时（\(Int(timeout)) 秒）。", "\(method) timed out (\(Int(timeout)) s).")))
                throw MCPError.message(tr("\(method) 超时。", "\(method) timed out."))
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private func allocateID() -> Int {
        lock.lock(); defer { lock.unlock() }
        nextID += 1
        return nextID - 1
    }

    private func park(_ id: Int, _ waiter: CheckedContinuation<[String: Any], Error>) {
        lock.lock(); defer { lock.unlock() }
        waiting[id] = waiter
    }

    private func take(_ id: Int) -> CheckedContinuation<[String: Any], Error>? {
        lock.lock(); defer { lock.unlock() }
        return waiting.removeValue(forKey: id)
    }

    // MARK: streamable HTTP

    private func post(_ message: [String: Any], expectID: Int?) async throws -> [String: Any]? {
        guard let url = URL(string: config.url) else { throw MCPError.message(tr("地址无效。", "Invalid URL.")) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        for (k, v) in config.headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.message(tr("连接失败。", "Connection failed.")) }
        if let session = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = session }
        guard (200..<300).contains(http.statusCode) else { throw MCPError.message("HTTP \(http.statusCode)") }
        guard let expectID else { return nil }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if type.contains("text/event-stream") {
            let text = String(decoding: data, as: UTF8.self)
            for line in text.components(separatedBy: "\n") where line.hasPrefix("data:") {
                let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                   ((json["id"] as? Int) ?? (json["id"] as? NSNumber)?.intValue) == expectID { return json }
            }
            return nil
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Owns server configs, live connections and their tools.
@MainActor @Observable
final class MCPManager {
    static let shared = MCPManager()

    var servers: [MCPServerConfig] = []
    var status: [String: String] = [:]      // name -> "connecting" | "connected" | "error: …" | "off"
    var tools: [String: [MCPTool]] = [:]
    @ObservationIgnored private var connections: [String: MCPConnection] = [:]
    @ObservationIgnored private var started = false

    nonisolated static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GrokMac/mcp.json")
    }

    nonisolated static func qualified(_ server: String, _ tool: String) -> String {
        func clean(_ s: String) -> String { String(s.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }) }
        return String("mcp__\(clean(server))__\(clean(tool))".prefix(64))
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        load()
        connectAll()
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = json["mcpServers"] as? [String: [String: Any]] else { servers = []; return }
        servers = map.keys.sorted().map { name in
            let raw = map[name] ?? [:]
            return MCPServerConfig(
                name: name,
                command: raw["command"] as? String ?? "",
                args: raw["args"] as? [String] ?? [],
                env: raw["env"] as? [String: String] ?? [:],
                url: raw["url"] as? String ?? "",
                headers: raw["headers"] as? [String: String] ?? [:],
                enabled: !(raw["disabled"] as? Bool ?? false),
                alwaysAllow: raw["grokAlwaysAllow"] as? Bool ?? false)
        }
    }

    func save() {
        var map: [String: Any] = [:]
        for server in servers {
            var raw: [String: Any] = [:]
            if server.isHTTP {
                raw["url"] = server.url
                if !server.headers.isEmpty { raw["headers"] = server.headers }
            } else {
                raw["command"] = server.command
                raw["args"] = server.args
                if !server.env.isEmpty { raw["env"] = server.env }
            }
            if !server.enabled { raw["disabled"] = true }
            if server.alwaysAllow { raw["grokAlwaysAllow"] = true }
            map[server.name] = raw
        }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": map], options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    func upsert(_ server: MCPServerConfig, replacing old: String?) {
        if let old { disconnect(old); servers.removeAll { $0.name == old } }
        servers.removeAll { $0.name == server.name }
        servers.append(server)
        servers.sort { $0.name < $1.name }
        save()
        connect(server.name)
    }

    func remove(_ name: String) {
        disconnect(name)
        servers.removeAll { $0.name == name }
        status[name] = nil
        save()
    }

    func setEnabled(_ name: String, _ on: Bool) {
        guard let index = servers.firstIndex(where: { $0.name == name }) else { return }
        servers[index].enabled = on
        save()
        if on { connect(name) } else { disconnect(name); status[name] = "off" }
    }

    func setAlwaysAllow(_ name: String, _ on: Bool) {
        guard let index = servers.firstIndex(where: { $0.name == name }) else { return }
        servers[index].alwaysAllow = on
        save()
    }

    func connectAll() { for server in servers { if server.enabled { connect(server.name) } else { status[server.name] = "off" } } }

    func disconnect(_ name: String) {
        connections.removeValue(forKey: name)?.stop()
        tools[name] = nil
    }

    func connect(_ name: String) {
        disconnect(name)
        guard let server = servers.first(where: { $0.name == name }), server.enabled else { return }
        let connection = MCPConnection(config: server)
        connections[name] = connection
        status[name] = "connecting"
        Task {
            do {
                try await connection.start()
                let list = try await connection.listTools()
                guard self.connections[name] === connection else { return }
                self.tools[name] = list
                self.status[name] = "connected"
            } catch {
                guard self.connections[name] === connection else { return }
                connection.stop()
                let tail = connection.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                self.status[name] = "error: " + ((error as? LocalizedError)?.errorDescription ?? "\(error)") + (tail.isEmpty ? "" : " " + String(tail.suffix(160)))
            }
        }
    }

    var activeTools: [MCPTool] {
        servers.filter { $0.enabled && status[$0.name] == "connected" }.flatMap { tools[$0.name] ?? [] }
    }

    func tool(named full: String) -> MCPTool? { activeTools.first { $0.fullName == full } }

    func alwaysAllowed(_ server: String) -> Bool { servers.first { $0.name == server }?.alwaysAllow ?? false }

    func promptLine() -> String {
        let live = servers.filter { $0.enabled && status[$0.name] == "connected" }
        guard !live.isEmpty else {
            return "No MCP servers are connected. If the user mentions an MCP server or pastes MCP tool docs, explain that pasting docs does not add tools: they must add the server in Settings → MCP 服务器 (命令 or URL)."
        }
        let names = live.map { "\($0.name) (\(tools[$0.name]?.count ?? 0) tools)" }.joined(separator: ", ")
        return "Connected MCP servers: \(names). Their tools are available as functions named mcp__<server>__<tool>; call them directly when the user asks for what they do."
    }

    /// Runs a call and flattens the MCP content blocks: text joined, images saved to temp files.
    func call(_ tool: MCPTool, arguments: String) async -> (text: String, images: [String], ok: Bool) {
        guard let connection = connections[tool.server] else { return (tr("服务器 \(tool.server) 没有连接。", "Server \(tool.server) isn't connected."), [], false) }
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        do {
            let result = try await connection.call(tool.name, arguments: args)
            var texts: [String] = []
            var images: [String] = []
            for block in result["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String ?? "" {
                case "text":
                    texts.append(block["text"] as? String ?? "")
                case "image":
                    if let b64 = block["data"] as? String, let data = Data(base64Encoded: b64) {
                        let ext = (block["mimeType"] as? String ?? "").contains("jpeg") ? "jpg" : "png"
                        let dir = Self.fileURL.deletingLastPathComponent().appendingPathComponent("mcp-images", isDirectory: true)
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        let url = dir.appendingPathComponent("\(tool.server)-\(UUID().uuidString.prefix(8)).\(ext)")
                        if (try? data.write(to: url)) != nil { images.append(url.path) }
                        texts.append(tr("[图片 \(url.lastPathComponent)]", "[image \(url.lastPathComponent)]"))
                    }
                case "resource":
                    let res = block["resource"] as? [String: Any] ?? [:]
                    texts.append((res["text"] as? String) ?? "[resource \(res["uri"] as? String ?? "")]")
                case "resource_link":
                    texts.append("[link \(block["uri"] as? String ?? "")]")
                default:
                    texts.append("[\(block["type"] as? String ?? "?")]")
                }
            }
            if texts.isEmpty, let structured = result["structuredContent"],
               let data = try? JSONSerialization.data(withJSONObject: structured, options: [.prettyPrinted]) {
                texts.append(String(decoding: data, as: UTF8.self))
            }
            let isError = result["isError"] as? Bool ?? false
            return (String(texts.joined(separator: "\n").prefix(20_000)), images, !isError)
        } catch {
            return ((error as? LocalizedError)?.errorDescription ?? "\(error)", [], false)
        }
    }
}

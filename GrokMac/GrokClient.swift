import Foundation

enum GrokClientError: LocalizedError {
    case missingKey
    case badStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            "还没有 API Key。用 ⌘, 填入你自己的 xAI Key，它只保存在这台 Mac 的钥匙串里。"
        case .badStatus(_, let message):
            message
        }
    }
}

enum GrokClient {
    static func stream(
        key: String,
        history: [ChatMessage],
        tier: ReplyTier,
        mode: AgentMode,
        surface: ChatSurface,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GrokClientError.missingKey }

        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let prior = history
            .filter { $0.role == .user || $0.role == .assistant }
            .suffix(16)
            .map { ["role": $0.role.rawValue, "content": String($0.content.prefix(6000))] }
        let payload: [String: Any] = [
            "model": "grok-4.5",
            "stream": true,
            "temperature": tier.temperature,
            "max_tokens": tier.maxTokens,
            "messages": [["role": "system", "content": systemPrompt(tier: tier, mode: mode, surface: surface)]] + prior,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GrokClientError.badStatus(-1, "连接 Grok 失败。")
        }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw GrokClientError.badStatus(http.statusCode, friendly(http.statusCode, data))
        }

        for try await line in bytes.lines {
            if Task.isCancelled { break }
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard trimmedLine.hasPrefix("data:") else { continue }
            let raw = trimmedLine.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if raw.isEmpty || raw == "[DONE]" { continue }
            guard let blob = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String,
                  !content.isEmpty
            else { continue }
            await MainActor.run { onDelta(content) }
        }
    }

    private static func systemPrompt(tier: ReplyTier, mode: AgentMode, surface: ChatSurface) -> String {
        let modeLine: String
        switch mode {
        case .plan:
            modeLine = "Plan mode: propose a concrete plan. Do not invent applied diffs."
        case .ask:
            modeLine = "Ask mode: answer only. Do not turn it into an implementation log."
        case .code:
            modeLine = "Code mode: give code and steps they can apply themselves, clearly as suggestions."
        }
        return [
            "You are Grok, built by xAI, inside a native Mac app that shows a grok.com-style chat and a Grok Build terminal together.",
            "Both panes share one thread. Reply in the user's language. Use markdown when it helps.",
            "You cannot read or write files on the user's computer and you cannot run their shell. Never pretend an edit or command already happened.",
            "Surface: \(surface.rawValue). Mode: \(mode.rawValue).",
            modeLine,
            tier.styleHint,
        ].joined(separator: " ")
    }

    private static func friendly(_ status: Int, _ data: Data) -> String {
        if status == 429 { return "额度或频率受限，请稍后再试。" }
        if status == 401 || status == 403 { return "Key 没有通过验证。打开设置（⌘,）检查 xAI API Key。" }
        var detail = ""
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let text = json["error"] as? String {
                detail = text
            } else if let object = json["error"] as? [String: Any], let text = object["message"] as? String {
                detail = text
            }
        }
        detail = detail.replacingOccurrences(of: #"xai-[A-Za-z0-9_-]+"#, with: "", options: .regularExpression)
        if detail.count > 160 { detail = String(detail.prefix(160)) }
        return detail.isEmpty ? "Grok 没有完成回答（\(status)）。" : "Grok 没有完成回答。\(detail)"
    }

    static func runAgent(
        key: String,
        history: [ChatMessage],
        root: URL,
        onTool: @escaping @MainActor (ToolTrace) -> Void,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GrokClientError.missingKey }

        var messages: [[String: Any]] = [[
            "role": "system",
            "content": """
            You are Grok, a coding agent on the user's Mac with the same tools as Codex and Claude Code: bash, read_file, write_file, edit_file, glob, grep, web_search, web_fetch, todo_write, generate_image.
            The working directory is the project folder the user selected. Paths are relative to it. bash starts there.
            Use tools to inspect and change that project. Never claim a command ran or a file changed unless the tool result says so.
            Do not read secrets outside the project. Reply in the user's language and finish with what you actually did.
            """,
        ]]
        for message in history.suffix(24) {
            if message.role == .tool, let tool = message.tool {
                messages.append(["role": "assistant", "content": String("[\(tool.name)] \(tool.input)\n\(tool.output)".prefix(4000))])
            } else if (message.role == .user || message.role == .assistant), !message.content.isEmpty {
                messages.append(["role": message.role.rawValue, "content": String(message.content.prefix(6000))])
            }
        }

        for _ in 0..<10 {
            if Task.isCancelled { return }
            let turn = try await complete(key: trimmed, messages: messages)
            if turn.calls.isEmpty {
                if !turn.text.isEmpty { await onDelta(turn.text) }
                return
            }
            let assistant: [String: Any] = [
                "role": "assistant",
                "content": turn.text.isEmpty ? NSNull() : turn.text,
                "tool_calls": turn.calls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": ["name": call.name, "arguments": call.arguments],
                    ]
                },
            ]
            messages.append(assistant)
            for call in turn.calls {
                if Task.isCancelled { return }
                await onTool(ToolTrace(id: call.id, name: call.name, input: call.arguments, output: "", status: "running"))
                let (output, ok) = await LocalTools.run(name: call.name, arguments: call.arguments, root: root, key: trimmed)
                await onTool(ToolTrace(id: call.id, name: call.name, input: call.arguments, output: output, status: ok ? "done" : "error"))
                messages.append(["role": "tool", "tool_call_id": call.id, "content": output])
            }
        }
        await onDelta("这一轮的工具次数用完了。")
    }

    private struct ToolCall {
        var id: String
        var name: String
        var arguments: String
    }

    private static func complete(key: String, messages: [[String: Any]]) async throws -> (text: String, calls: [ToolCall]) {
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "model": "grok-4.5",
            "temperature": 0.2,
            "messages": messages,
            "tools": agentTools,
            "tool_choice": "auto",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GrokClientError.badStatus(-1, "连接 Grok 失败。") }
        guard http.statusCode == 200 else { throw GrokClientError.badStatus(http.statusCode, friendly(http.statusCode, data)) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else { throw GrokClientError.badStatus(-1, "Grok 没有完成回答。") }
        let text = message["content"] as? String ?? ""
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).enumerated().compactMap { index, call -> ToolCall? in
            guard let function = call["function"] as? [String: Any], let name = function["name"] as? String, !name.isEmpty else { return nil }
            return ToolCall(id: call["id"] as? String ?? "call_\(index)", name: name, arguments: function["arguments"] as? String ?? "{}")
        }
        return (text, calls)
    }

    private static let agentTools: [[String: Any]] = [
        tool("bash", "Run a shell command in the selected project. The current directory is that folder.", ["command"]),
        tool("read_file", "Read a text file. offset and limit are 1-based line numbers.", ["path"], extra: ["offset": "number", "limit": "number"]),
        tool("write_file", "Create or replace a text file in the project.", ["path", "content"]),
        tool("edit_file", "Replace one exact occurrence of old_string with new_string.", ["path", "old_string", "new_string"]),
        tool("glob", "Find files whose relative path contains the pattern.", ["pattern"]),
        tool("grep", "Search file contents. path is an optional relative prefix.", ["pattern"], extra: ["path": "string"]),
        tool("web_search", "Search the live web and X.", ["query"]),
        tool("web_fetch", "Fetch a public http(s) URL and return text.", ["url"]),
        tool("todo_write", "Replace the project task list.", [], extra: ["todos": "array"]),
        tool("generate_image", "Generate an image and return its URL.", ["prompt"]),
    ]

    private static func tool(_ name: String, _ description: String, _ required: [String], extra: [String: String] = [:]) -> [String: Any] {
        var properties: [String: Any] = [:]
        for name in required {
            properties[name] = ["type": "string"]
        }
        for (name, type) in extra where properties[name] == nil {
            properties[name] = ["type": type]
        }
        var parameters: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { parameters["required"] = required }
        return ["type": "function", "function": ["name": name, "description": description, "parameters": parameters]]
    }
}

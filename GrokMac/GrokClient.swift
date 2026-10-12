import Foundation

enum GrokClientError: LocalizedError {
    case missingKey
    case badStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            "先登录，或点暂时跳过。这个应用不再要 API Key。"
        case .badStatus(_, let message):
            message
        }
    }
}

enum GrokClient {
    enum StreamEvent {
        case text(String)
        case reasoning(String)
        case citations([String])
    }

    /// Streams a reply over the Responses API: https://docs.x.ai/developers/rest-api-reference/inference/responses
    /// The multi-agent model only works there: https://docs.x.ai/developers/model-capabilities/text/multi-agent
    static func stream(
        key: String,
        history: [ChatMessage],
        tier: ReplyTier,
        mode: AgentMode,
        surface: ChatSurface,
        note: String = "",
        search: [String] = [],
        onEvent: @escaping @MainActor (StreamEvent) -> Void
    ) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GrokClientError.missingKey }

        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = tier == .heavy ? 900 : 300

        let prior: [[String: Any]] = history
            .filter { $0.role == .user || $0.role == .assistant }
            .suffix(16)
            .map { message in
                let text = String(message.promptText.prefix(message.context == nil ? 6000 : 6000 + ComposerAttachment.maxPDFChars))
                let images = message.role == .user ? message.allImages : []
                if images.isEmpty { return ["role": message.role.rawValue, "content": text] }
                // input_image parts: https://docs.x.ai/developers/model-capabilities/images/understanding
                let parts: [[String: Any]] = [["type": "input_text", "text": text]]
                    + images.map { ["type": "input_image", "image_url": $0, "detail": "high"] }
                return ["role": "user", "content": parts]
            }
        var payload: [String: Any] = [
            "model": tier.modelID,
            "stream": true,
            "store": false,
            "input": [["role": "system", "content": systemPrompt(tier: tier, mode: mode, surface: surface) + (note.isEmpty ? "" : "\n" + note)]] + prior,
        ]
        // Server-side search tools: https://docs.x.ai/docs/guides/tools/search-tools and https://docs.x.ai/developers/tools/x-search
        if !search.isEmpty {
            payload["tools"] = search.map { ["type": $0] }
        }
        if let effort = tier.effort {
            payload["reasoning"] = ["effort": effort]
        }
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
                  let json = try? JSONSerialization.jsonObject(with: blob) as? [String: Any]
            else { continue }
            let type = json["type"] as? String ?? ""
            switch type {
            case "response.output_text.delta":
                if let delta = json["delta"] as? String, !delta.isEmpty {
                    await MainActor.run { onEvent(.text(delta)) }
                }
            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                if let delta = json["delta"] as? String, !delta.isEmpty {
                    await MainActor.run { onEvent(.reasoning(delta)) }
                }
            case "response.completed":
                let links = citations(in: json["response"] as? [String: Any] ?? [:])
                if !links.isEmpty { await MainActor.run { onEvent(.citations(links)) } }
            case "response.failed", "error":
                let body = (json["response"] as? [String: Any])?["error"] as? [String: Any] ?? json["error"] as? [String: Any] ?? json
                let detail = body["message"] as? String ?? ""
                throw GrokClientError.badStatus(-1, detail.isEmpty ? "Grok 没有完成回答。" : "Grok 没有完成回答。\(detail.prefix(160))")
            default:
                continue
            }
        }
    }

    /// `citations` on the response plus url_citation annotations: https://docs.x.ai/developers/tools/citations
    private static func citations(in response: [String: Any]) -> [String] {
        var links = response["citations"] as? [String] ?? []
        for item in response["output"] as? [[String: Any]] ?? [] {
            for part in item["content"] as? [[String: Any]] ?? [] {
                for note in part["annotations"] as? [[String: Any]] ?? [] {
                    if let url = note["url"] as? String { links.append(url) }
                }
            }
        }
        var seen = Set<String>()
        return links.filter { $0.hasPrefix("http") && seen.insert($0).inserted }
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
        if status == 401 || status == 403 { return "账号没有通过。再点一次登录。" }
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
        mode: AgentMode,
        sandbox: String,
        approval: String,
        note: String = "",
        onTool: @escaping @MainActor (ToolTrace) -> Void,
        onGate: @escaping @MainActor (String, String, String) async -> String,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GrokClientError.missingKey }
        let brief = LocalTools.projectBrief(root)
        let modeLine = mode == .ask ? "Mode: ask. Read only." : mode == .plan ? "Mode: plan. Read only, todos allowed." : "Mode: code. Edits wait for approval unless auto-run is on."
        var messages: [[String: Any]] = [[
            "role": "system",
            "content": """
            You are Grok running as a local agent, the same loop as Codex. File tools and local commands stay inside the selected project. Do not claim a change unless a tool result says so.
            \(modeLine)
            Sandbox: \(sandbox). Approval: \(approval). Workspace writes and local commands proceed. Network or leaving the project waits for approval.
            \(note)
            Use ask_user when you need a decision. Use run_tests after code changes. Use apply_patch for multi-line edits.
            \(brief.isEmpty ? "" : "Project notes:\n\(brief)")
            """,
        ]]
        for message in history.suffix(24) {
            if message.role == .tool, let tool = message.tool {
                messages.append(["role": "assistant", "content": String("[\(tool.name)] \(tool.input)\n\(tool.output)".prefix(4000))])
            } else if message.role == .user, !message.allImages.isEmpty {
                let parts: [[String: Any]] = [["type": "text", "text": String(message.promptText.prefix(6000 + ComposerAttachment.maxPDFChars))]]
                    + message.allImages.map { ["type": "image_url", "image_url": ["url": $0]] }
                messages.append(["role": "user", "content": parts])
            } else if (message.role == .user || message.role == .assistant), !message.content.isEmpty {
                messages.append(["role": message.role.rawValue, "content": String(message.promptText.prefix(message.context == nil ? 6000 : 6000 + ComposerAttachment.maxPDFChars))])
            }
        }

        let visible = agentTools.filter { tool in
            let name = ((tool["function"] as? [String: Any])?["name"] as? String) ?? ""
            return allowed(mode, name)
        }
        for _ in 0..<16 {
            if Task.isCancelled { return }
            let turn = try await complete(key: trimmed, messages: messages, tools: visible)
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
                if !allowed(mode, call.name) {
                    let output = "当前是\(mode == .ask ? "提问" : "计划")模式，不能改文件或执行命令。"
                    await onTool(ToolTrace(id: call.id, name: call.name, input: call.arguments, output: output, status: "error"))
                    messages.append(["role": "tool", "tool_call_id": call.id, "content": output])
                    continue
                }
                if call.name == "ask_user" {
                    let question = (jsonObject(call.arguments)["question"] as? String) ?? "继续吗？"
                    await onTool(ToolTrace(id: call.id, name: call.name, input: question, output: "", status: "ask"))
                    let answer = await onGate("需要你回答", question, "ask")
                    let output = answer == "no" || answer.isEmpty ? "用户没有回答。" : answer
                    await onTool(ToolTrace(id: call.id, name: call.name, input: question, output: output, status: "done"))
                    messages.append(["role": "tool", "tool_call_id": call.id, "content": output])
                    continue
                }
                if let reason = escalation(name: call.name, arguments: call.arguments, sandbox: sandbox, approval: approval) {
                    await onTool(ToolTrace(id: call.id, name: call.name, input: call.arguments, output: "", status: "approval"))
                    let answer = await onGate(reason, call.arguments, "approve")
                    if answer != "yes" {
                        let output = "用户拒绝了越界操作。"
                        await onTool(ToolTrace(id: call.id, name: call.name, input: call.arguments, output: output, status: "error"))
                        messages.append(["role": "tool", "tool_call_id": call.id, "content": output])
                        continue
                    }
                }
                let access = accessLevel(name: call.name, arguments: call.arguments, sandbox: sandbox, approval: approval)
                await onTool(ToolTrace(id: call.id, name: call.name, input: call.arguments, output: "", status: "running"))
                let (output, ok) = await LocalTools.run(name: call.name, arguments: call.arguments, root: root, key: trimmed, access: access)
                await onTool(ToolTrace(id: call.id, name: call.name, input: call.arguments, output: output, status: ok ? "done" : "error"))
                messages.append(["role": "tool", "tool_call_id": call.id, "content": output])
            }
        }
        await onDelta("这一轮的工具次数用完了。")
    }

    private static let readOnly: Set<String> = ["read_file", "glob", "grep", "codebase_search", "web_search", "web_fetch", "ask_user", "undo"]
    private static let mutating: Set<String> = ["bash", "write_file", "edit_file", "apply_patch", "run_tests", "open_pr"]
    private static let networked: Set<String> = ["web_search", "web_fetch", "open_pr", "generate_image"]

    private static func needsNetwork(_ command: String) -> Bool {
        let text = command.lowercased()
        let words = ["curl", "wget", "ssh", "scp", "rsync", "ping", "npm", "pnpm", "yarn", "pip", "pip3", "brew", "gh", "docker", "podman"]
        if words.contains(where: { text.contains($0) }) { return true }
        return text.contains("git push") || text.contains("git pull") || text.contains("git fetch") || text.contains("git clone")
    }

    private static func escalation(name: String, arguments: String, sandbox: String, approval: String) -> String? {
        let command = (jsonObject(arguments)["command"] as? String) ?? ""
        let writes = mutating.contains(name) || name == "todo_write" || name == "undo"
        if sandbox == "read-only", writes {
            return approval == "never" ? nil : "只读沙箱。允许这一次写出或执行？"
        }
        if networked.contains(name) || ((name == "bash" || name == "run_tests") && needsNetwork(command)) {
            return approval == "never" ? nil : "需要联网。允许这一次？"
        }
        if sandbox == "full-access" && (name == "bash" || name == "run_tests") && approval != "never" {
            return "完全访问。允许这条命令？"
        }
        return nil
    }

    private static func accessLevel(name: String, arguments: String, sandbox: String, approval: String) -> String {
        if sandbox == "full-access" { return "full" }
        let command = (jsonObject(arguments)["command"] as? String) ?? ""
        let wantsNet = networked.contains(name) || ((name == "bash" || name == "run_tests") && needsNetwork(command))
        if wantsNet, approval == "never" { return "workspace" }
        if wantsNet { return "workspace-net" }
        if sandbox == "read-only" { return approval == "never" ? "read-only" : "workspace" }
        return "workspace"
    }

    private static func allowed(_ mode: AgentMode, _ name: String) -> Bool {
        if mode == .ask { return readOnly.contains(name) }
        if mode == .plan { return readOnly.contains(name) || name == "todo_write" }
        return true
    }

    private static func jsonObject(_ raw: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    }

    private struct ToolCall {
        var id: String
        var name: String
        var arguments: String
    }

    private static func complete(key: String, messages: [[String: Any]], tools: [[String: Any]]) async throws -> (text: String, calls: [ToolCall]) {
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "model": "grok-4.7",
            "temperature": 0.2,
            "messages": messages,
            "tools": tools,
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
        tool("grep", "Search file contents with a regular expression. path is an optional relative prefix.", ["pattern"], extra: ["path": "string"]),
        tool("codebase_search", "Find the project snippets that best match the words.", ["query"]),
        tool("web_search", "Search the live web and X.", ["query"]),
        tool("web_fetch", "Fetch a public http(s) URL and return text.", ["url"]),
        tool("todo_write", "Replace the project task list.", [], extra: ["todos": "array"]),
        tool("generate_image", "Generate an image and return its URL.", ["prompt"]),
        tool("ask_user", "Ask the user a question and wait.", ["question"]),
        tool("undo", "Undo the last file change.", []),
        tool("run_tests", "Run the project tests. Pass command when the default is wrong.", [], extra: ["command": "string"]),
        tool("open_pr", "Create a GitHub pull request with gh.", ["title"], extra: ["body": "string"]),
        tool("apply_patch", "Apply a Codex-style patch with *** Add File, *** Update File, or *** Delete File.", ["patch"]),
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

    static func imagine(key: String, prompt: String) async throws -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GrokClientError.missingKey }
        for model in ["grok-imagine-image-2.0", "grok-imagine-image"] {
            var request = URLRequest(url: URL(string: "https://api.x.ai/v1/images/generations")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "prompt": String(prompt.prefix(2000)), "n": 1])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rows = json?["data"] as? [[String: Any]]
            if let url = rows?.first?["url"] as? String, !url.isEmpty { return url }
        }
        throw GrokClientError.badStatus(-1, "没有生成图片。")
    }

    /// Async video generation: POST /v1/videos/generations then poll GET /v1/videos/{request_id}.
    /// https://docs.x.ai/developers/rest-api-reference/inference/videos
    static func imagineVideo(key: String, prompt: String, onProgress: @escaping @MainActor (Int) -> Void) async throws -> URL {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GrokClientError.missingKey }
        var requestID = ""
        var lastStatus = 0
        var lastData = Data()
        for model in ["grok-imagine-video-1.5", "grok-imagine-video"] {
            var request = URLRequest(url: URL(string: "https://api.x.ai/v1/videos/generations")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "prompt": String(prompt.prefix(4000))])
            let (data, response) = try await URLSession.shared.data(for: request)
            lastStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
            lastData = data
            guard (200..<300).contains(lastStatus) else {
                if lastStatus == 401 || lastStatus == 403 || lastStatus == 429 { break }
                continue
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            requestID = json?["request_id"] as? String ?? ""
            if !requestID.isEmpty { break }
        }
        guard !requestID.isEmpty else {
            throw GrokClientError.badStatus(lastStatus, lastStatus == -1 ? "没有生成视频。" : friendly(lastStatus, lastData).replacingOccurrences(of: "回答", with: "视频"))
        }

        let deadline = Date().addingTimeInterval(15 * 60)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(4))
            var poll = URLRequest(url: URL(string: "https://api.x.ai/v1/videos/\(requestID)")!)
            poll.timeoutInterval = 60
            poll.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: poll)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                if status >= 400 { throw GrokClientError.badStatus(status, friendly(status, data)) }
                continue
            }
            switch json["status"] as? String ?? "" {
            case "done":
                let video = json["video"] as? [String: Any]
                if video?["respect_moderation"] as? Bool == false {
                    throw GrokClientError.badStatus(-1, "视频没有通过内容审核。")
                }
                guard let raw = video?["url"] as? String, let url = URL(string: raw) else {
                    throw GrokClientError.badStatus(-1, "没有拿到视频地址。")
                }
                return url
            case "failed", "expired":
                let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? ""
                throw GrokClientError.badStatus(-1, message.isEmpty ? "视频生成失败。" : "视频生成失败。\(message.prefix(160))")
            default:
                if let progress = json["progress"] as? Int {
                    await MainActor.run { onProgress(progress) }
                }
                if status >= 400 { throw GrokClientError.badStatus(status, friendly(status, data)) }
            }
        }
        throw GrokClientError.badStatus(-1, "视频生成超时。")
    }
}

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

    /// One streamed Responses API turn: https://docs.x.ai/developers/rest-api-reference/inference/responses
    /// Returns every output item so reasoning (encrypted_content) and function_call items can be replayed with store=false.
    private static func turn(
        key: String,
        model: String,
        effort: String?,
        input: [[String: Any]],
        tools: [[String: Any]],
        onEvent: @escaping @MainActor (StreamEvent) -> Void
    ) async throws -> [[String: Any]] {
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = model.contains("multi-agent") ? 900 : 300
        var payload: [String: Any] = ["model": model, "stream": true, "store": false, "input": input]
        if !tools.isEmpty { payload["tools"] = tools }
        if let effort { payload["reasoning"] = ["effort": effort] }
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

        var items: [[String: Any]] = []
        var finished: [[String: Any]]?
        for try await line in bytes.lines {
            if Task.isCancelled { break }
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard trimmedLine.hasPrefix("data:") else { continue }
            let raw = trimmedLine.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if raw.isEmpty || raw == "[DONE]" { continue }
            guard let blob = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: blob) as? [String: Any]
            else { continue }
            switch json["type"] as? String ?? "" {
            case "response.output_text.delta":
                if let delta = json["delta"] as? String, !delta.isEmpty {
                    await MainActor.run { onEvent(.text(delta)) }
                }
            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                if let delta = json["delta"] as? String, !delta.isEmpty {
                    await MainActor.run { onEvent(.reasoning(delta)) }
                }
            case "response.output_item.done":
                if let item = json["item"] as? [String: Any] { items.append(item) }
            case "response.completed":
                let body = json["response"] as? [String: Any] ?? [:]
                finished = body["output"] as? [[String: Any]]
                let links = citations(in: body)
                if !links.isEmpty { await MainActor.run { onEvent(.citations(links)) } }
            case "response.failed", "error":
                let body = (json["response"] as? [String: Any])?["error"] as? [String: Any] ?? json["error"] as? [String: Any] ?? json
                let detail = body["message"] as? String ?? ""
                throw GrokClientError.badStatus(-1, detail.isEmpty ? "Grok 没有完成回答。" : "Grok 没有完成回答。\(detail.prefix(160))")
            default:
                continue
            }
        }
        return finished ?? items
    }

    /// Sources for this response only: https://docs.x.ai/developers/tools/citations
    /// `response.citations` is used only when this response actually ran a server-side search, so links
    /// echoed from earlier turns in the input never show up under a new reply.
    private static func citations(in response: [String: Any]) -> [String] {
        let output = response["output"] as? [[String: Any]] ?? []
        let searched = output.contains { (($0["type"] as? String) ?? "").hasSuffix("search_call") }
        var links = searched ? (response["citations"] as? [String] ?? []) : []
        for item in output where (item["type"] as? String) == "message" {
            for part in item["content"] as? [[String: Any]] ?? [] {
                for note in part["annotations"] as? [[String: Any]] ?? [] where (note["type"] as? String) == "url_citation" {
                    if let url = note["url"] as? String { links.append(url) }
                }
            }
        }
        var seen = Set<String>()
        return links.filter { $0.hasPrefix("http") && seen.insert($0).inserted }
    }

    /// Drops inline `[[n]](url)` citation links from earlier replies before they are sent back as history.
    private static func strippingCitations(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s?\[\[\d+\]\]\([^)\s]+\)"#, with: "", options: .regularExpression)
    }

    private static func systemPrompt(tier: ReplyTier, mode: AgentMode, root: URL, projectChosen: Bool, sandbox: String, approval: String) -> String {
        let modeLine: String
        switch mode {
        case .plan:
            modeLine = "Plan mode: read and inspect freely, propose a concrete plan, do not edit files."
        case .ask:
            modeLine = "Ask mode: answer the question. You may read files and run read-only checks, but do not change anything."
        case .code:
            modeLine = "Code mode: you may edit files and run commands to get the task done."
        }
        let place = projectChosen
            ? "The working folder is the user's selected project: \(root.path)."
            : "No project folder is selected, so the working folder is the user's home folder: \(root.path)."
        return [
            "You are Grok, built by xAI, inside a native Mac app with a grok.com-style chat. Reply in the user's language. Use markdown when it helps.",
            "You CAN run shell commands and read and write files on the user's Mac through the bash, read_file, write_file, edit_file, apply_patch, glob and grep tools. Use them whenever the user asks about their Mac, files, code, or anything a command can answer, instead of guessing.",
            place,
            "Commands run with /bin/bash as the user. You can read anywhere in their home folder and write there too; destructive commands and edits outside the working folder wait for the user's approval. Sandbox setting: \(sandbox). Approval: \(approval). Risky or networked commands wait for the user's approval.",
            "Never claim a command ran or a file changed unless a tool result says so. Keep tool output summaries short; the user already sees each command and its output in the chat.",
            "Use ask_user when you need a decision.",
            modeLine,
            tier.styleHint,
        ].joined(separator: " ")
    }

    /// Set once xAI refuses client-side tools for the multi-agent model, so later turns go straight to Expert.
    @MainActor private static var heavyToolsRefused = false

    private static func friendly(_ status: Int, _ data: Data) -> String {
        if status == 429 {
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("at capacity") || body.contains("resource-exhausted") {
                return "这个模型现在太忙，请过几分钟再试，或先换成 Expert。"
            }
            return "额度或频率受限，请稍后再试。"
        }
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

    /// The chat agent loop over the Responses API with function tools:
    /// https://docs.x.ai/developers/tools/function-calling
    static func runAgent(
        key: String,
        history: [ChatMessage],
        root: URL,
        projectChosen: Bool,
        tier: ReplyTier,
        mode: AgentMode,
        sandbox: String,
        approval: String,
        note: String = "",
        search: [String] = [],
        onTool: @escaping @MainActor (ToolTrace) -> Void,
        onGate: @escaping @MainActor (String, String, String) async -> String,
        onEvent: @escaping @MainActor (StreamEvent) -> Void
    ) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GrokClientError.missingKey }
        let brief = projectChosen ? LocalTools.projectBrief(root) : ""
        var system = systemPrompt(tier: tier, mode: mode, root: root, projectChosen: projectChosen, sandbox: sandbox, approval: approval)
        if !note.isEmpty { system += "\n" + note }
        if !brief.isEmpty { system += "\nProject notes:\n" + brief }
        var input: [[String: Any]] = [["role": "system", "content": system]]
        for message in history.suffix(24) {
            if message.role == .tool, let tool = message.tool {
                input.append(["role": "assistant", "content": String("[\(tool.name)] \(tool.input)\n\(tool.output)".prefix(4000))])
            } else if message.role == .user, !message.allImages.isEmpty {
                // input_image parts: https://docs.x.ai/developers/model-capabilities/images/understanding
                let parts: [[String: Any]] = [["type": "input_text", "text": String(message.promptText.prefix(6000 + ComposerAttachment.maxPDFChars))]]
                    + message.allImages.map { ["type": "input_image", "image_url": $0, "detail": "high"] }
                input.append(["role": "user", "content": parts])
            } else if message.role == .assistant, !message.content.isEmpty {
                input.append(["role": "assistant", "content": String(strippingCitations(message.content).prefix(6000))])
            } else if message.role == .user, !message.content.isEmpty {
                input.append(["role": message.role.rawValue, "content": String(message.promptText.prefix(message.context == nil ? 6000 : 6000 + ComposerAttachment.maxPDFChars))])
            }
        }

        // Server-side search tools: https://docs.x.ai/docs/guides/tools/search-tools and https://docs.x.ai/developers/tools/x-search
        var tools: [[String: Any]] = search.map { ["type": $0] }
        for tool in agentTools {
            guard let function = tool["function"] as? [String: Any], let name = function["name"] as? String, allowed(mode, name) else { continue }
            if name == "web_search", search.contains("web_search") { continue }
            tools.append(["type": "function", "name": name, "description": function["description"] ?? "", "parameters": function["parameters"] ?? [:]])
        }

        var model = tier.modelID
        var effort = tier.effort
        let heavyRefused = await MainActor.run { heavyToolsRefused }
        if tier == .heavy, heavyRefused {
            model = ReplyTier.expert.modelID
            effort = ReplyTier.expert.effort
            await onEvent(.reasoning(heavyNotice))
        }

        for _ in 0..<24 {
            if Task.isCancelled { return }
            let output: [[String: Any]]
            do {
                output = try await turn(key: trimmed, model: model, effort: effort, input: input, tools: tools, onEvent: onEvent)
            } catch GrokClientError.badStatus(let status, let message) where status == 400 && model == ReplyTier.heavy.modelID && (message.contains("multi-agent") || message.contains("beta")) {
                // https://docs.x.ai/developers/model-capabilities/text/multi-agent: client-side tools are not available
                // to the multi-agent model without beta access, so this turn runs on Expert instead.
                await MainActor.run { heavyToolsRefused = true }
                model = ReplyTier.expert.modelID
                effort = ReplyTier.expert.effort
                await onEvent(.reasoning(heavyNotice))
                continue
            }
            input.append(contentsOf: output)
            let calls = output.filter { ($0["type"] as? String) == "function_call" }
            if calls.isEmpty { return }

            for item in calls {
                if Task.isCancelled { return }
                let call = ToolCall(
                    id: item["call_id"] as? String ?? item["id"] as? String ?? UUID().uuidString,
                    name: item["name"] as? String ?? "",
                    arguments: item["arguments"] as? String ?? "{}"
                )
                let result = await execute(call, root: root, key: trimmed, mode: mode, sandbox: sandbox, approval: approval, onTool: onTool, onGate: onGate)
                input.append(["type": "function_call_output", "call_id": call.id, "output": result])
            }
        }
        await onEvent(.text("\n\n这一轮的工具次数用完了。"))
    }

    private static let heavyNotice = "Heavy 多智能体模型调用本机工具需要 xAI 的 beta 权限，这一轮改用 Expert · grok-4.7。\n\n"

    private static func execute(
        _ call: ToolCall,
        root: URL,
        key: String,
        mode: AgentMode,
        sandbox: String,
        approval: String,
        onTool: @escaping @MainActor (ToolTrace) -> Void,
        onGate: @escaping @MainActor (String, String, String) async -> String
    ) async -> String {
        if !allowed(mode, call.name) {
            let output = "当前是\(mode == .ask ? "提问" : "计划")模式，不能改文件或执行命令。"
            await onTool(ToolTrace(id: call.id, name: call.name, input: call.arguments, output: output, status: "error"))
            return output
        }
        if call.name == "ask_user" {
            let question = (jsonObject(call.arguments)["question"] as? String) ?? "继续吗？"
            await onTool(ToolTrace(id: call.id, name: call.name, input: question, output: "", status: "ask"))
            let answer = await onGate("需要你回答", question, "ask")
            let output = answer == "no" || answer.isEmpty ? "用户没有回答。" : answer
            await onTool(ToolTrace(id: call.id, name: call.name, input: question, output: output, status: "done"))
            return output
        }
        let shown = displayInput(call)
        if let reason = escalation(name: call.name, arguments: call.arguments, root: root, sandbox: sandbox, approval: approval) {
            await onTool(ToolTrace(id: call.id, name: call.name, input: shown, output: "", status: "approval"))
            let answer = await onGate(reason, shown, "approve")
            if answer != "yes" {
                let output = "用户拒绝了这次操作。"
                await onTool(ToolTrace(id: call.id, name: call.name, input: shown, output: output, status: "error"))
                return output
            }
        }
        let access = accessLevel(name: call.name, arguments: call.arguments, sandbox: sandbox, approval: approval)
        await onTool(ToolTrace(id: call.id, name: call.name, input: shown, output: "", status: "running"))
        let (output, ok) = await LocalTools.run(name: call.name, arguments: call.arguments, root: root, key: key, access: access)
        await onTool(ToolTrace(id: call.id, name: call.name, input: shown, output: output, status: ok ? "done" : "error"))
        return output
    }

    /// The command itself for shell tools, otherwise the raw JSON arguments.
    private static func displayInput(_ call: ToolCall) -> String {
        let args = jsonObject(call.arguments)
        if let command = args["command"] as? String, !command.isEmpty { return command }
        if let path = args["path"] as? String, args.count == 1 { return path }
        return call.arguments
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

    private static func isDestructive(_ command: String) -> Bool {
        let text = " " + command.lowercased().replacingOccurrences(of: "\n", with: " ; ") + " "
        let patterns = [
            #"(^|[\s;&|(])(sudo\s+)?(rm|rmdir|unlink|shred|srm|mv|dd|mkfs\S*|diskutil|chmod|chown|chflags|truncate|killall|pkill|kill|launchctl|defaults\s+delete|osascript)\s"#,
            #"git\s+(reset\s+--hard|clean\s+-\S*f|checkout\s+--\s|restore\s|push\s+.*(-f|--force)|branch\s+-D|stash\s+(drop|clear))"#,
            #"(^|[^>])>\s*[~/]"#,
            #"find\s.*-delete"#,
            #"xargs\s+(rm|mv)"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static func outsidePath(_ arguments: String, root: URL) -> String? {
        let args = jsonObject(arguments)
        var paths = [args["path"] as? String].compactMap { $0 }
        if let patch = args["patch"] as? String {
            for line in patch.split(separator: "\n") {
                for marker in ["*** Add File: ", "*** Update File: ", "*** Delete File: "] where line.hasPrefix(marker) {
                    paths.append(String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
                }
            }
        }
        let base = root.standardizedFileURL.path
        for path in paths {
            guard let url = try? LocalTools.resolve(root, path) else { continue }
            if url.path != base, !url.path.hasPrefix(base + "/") { return url.path }
        }
        return nil
    }

    private static func escalation(name: String, arguments: String, root: URL, sandbox: String, approval: String) -> String? {
        let command = (jsonObject(arguments)["command"] as? String) ?? ""
        let writes = mutating.contains(name) || name == "todo_write" || name == "undo"
        if sandbox == "read-only", writes {
            return approval == "never" ? nil : "只读沙箱。允许这一次写出或执行？"
        }
        if approval != "never", (name == "bash" || name == "run_tests" || name == "open_pr"), isDestructive(command) {
            return "这条命令可能删除或覆盖文件。允许执行？"
        }
        if approval != "never", ["write_file", "edit_file", "apply_patch"].contains(name), let outside = outsidePath(arguments, root: root) {
            return "要改工程以外的文件：\(outside)。允许？"
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

    private static let agentTools: [[String: Any]] = [
        tool("bash", "Run a shell command with /bin/bash on the user's Mac. The current directory is the working folder. Output is capped and commands time out after 20 seconds.", ["command"]),
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

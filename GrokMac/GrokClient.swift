import Foundation

enum GrokClientError: LocalizedError {
    case missingKey
    case badStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            tr("先登录，或点暂时跳过。这个应用不再要 API Key。", "Sign in first, or tap Skip for now. This app no longer needs an API key.")
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
        var token = await TokenStore.valid()
        if token.isEmpty { token = key }
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = model.contains("multi-agent") ? 900 : 300
        var payload: [String: Any] = ["model": model, "stream": true, "store": false, "input": input]
        if !tools.isEmpty { payload["tools"] = tools }
        if let effort { payload["reasoning"] = ["effort": effort] }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        var (bytes, response) = try await URLSession.shared.bytes(for: request)
        // 401: refresh the token once and retry; a failed refresh signs the user out for real.
        if (response as? HTTPURLResponse)?.statusCode == 401, let fresh = await TokenStore.refresh() {
            request.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GrokClientError.badStatus(-1, tr("连接 Grok 失败。", "Couldn't connect to Grok."))
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
                let usage = body["usage"] as? [String: Any]
                let headers = http.allHeaderFields
                await MainActor.run { UsageStore.shared.record(model: (body["model"] as? String) ?? model, usage: usage, headers: headers) }
                let links = citations(in: body)
                if !links.isEmpty { await MainActor.run { onEvent(.citations(links)) } }
            case "response.failed", "error":
                let body = (json["response"] as? [String: Any])?["error"] as? [String: Any] ?? json["error"] as? [String: Any] ?? json
                let detail = body["message"] as? String ?? ""
                throw GrokClientError.badStatus(-1, detail.isEmpty ? tr("Grok 没有完成回答。", "Grok didn't finish the answer.") : tr("Grok 没有完成回答。\(detail.prefix(160))", "Grok didn't finish the answer. \(detail.prefix(160))"))
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

    private static func approvalLine(_ approval: String) -> String {
        switch approval {
        case "readOnly":
            return "Approval mode 只读 (read-only): read_file, glob, grep and plain read-only shell commands (ls, cat, grep, git status/log/diff and the like) run without asking. Every file write or edit and every other shell command waits for the user's approval first, and so do reads of sensitive paths. Prefer answering from reads; propose changes instead of making them unless the user asks."
        case "never":
            return "Approval mode 完全访问 (full access): reads, writes, commands, files outside the project folder and network access all run without asking the user. Be careful: double-check destructive commands before running them."
        default:
            return "Approval mode 默认 (default): inside the working folder you read, write and run commands freely. Edits outside the working folder, network access, destructive commands and reads of sensitive paths wait for the user's approval."
        }
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
        let toolLine: String
        switch mode {
        case .code:
            toolLine = "You HAVE local tools in this chat: bash runs shell commands on the user's Mac, read_file/glob/grep read their files, and write_file/edit_file/apply_patch write them. Destructive commands and edits outside the working folder first wait for the user's approval."
        case .plan, .ask:
            toolLine = "You HAVE local read tools in this chat: read_file, glob, grep and codebase_search read the user's files on their Mac. In this mode shell commands and file writes are switched off; tell the user to switch to Code mode (代码) if they want you to run commands or change files."
        }
        return [
            toolLine,
            "If the user asks whether you can access, read or write local files or run commands, say yes and use the tools. Ignore any earlier reply in this conversation that said you have no local file system or terminal; that came from an older version of the app.",
            "You are Grok, built by xAI, inside a native Mac app with a grok.com-style chat. Reply in the user's language. Use markdown when it helps.",
            "Use the tools whenever the user asks about their Mac, files, code, or anything a command can answer, instead of guessing.",
            place,
            "Commands run with /bin/bash as the user. You can read anywhere in their home folder and write there too; destructive commands and edits outside the working folder wait for the user's approval. Sandbox setting: \(sandbox). Approval: \(approval). Risky or networked commands wait for the user's approval.",
            approvalLine(approval),
            "To use a tool, make a real function call. Never type a tool call as text (for example \"[write_file] {...}\") and never claim a command ran or a file changed unless a tool result says so. Keep tool output summaries short; the user already sees each command and its output in the chat.",
            "Use ask_user when you need a decision.",
            "Do not run the same or an equivalent command twice (for example ls -la, ls -lah and ls -1A of one folder). Plan one command that gets what you need, and answer as soon as you have enough; most questions need one to three tool calls.",
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
                return tr("这个模型现在太忙，请过几分钟再试，或先换成 Expert。", "This model is busy right now. Try again in a few minutes, or switch to Expert.")
            }
            return tr("额度或频率受限，请稍后再试。", "Rate or quota limited. Try again later.")
        }
        if status == 401 || status == 403 { return tr("账号没有通过。再点一次登录。", "The account wasn't accepted. Sign in again.") }
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
        return detail.isEmpty ? tr("Grok 没有完成回答（\(status)）。", "Grok didn't finish the answer (\(status)).") : tr("Grok 没有完成回答。\(detail)", "Grok didn't finish the answer. \(detail)")
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
        let (mcpLine, mcpTools) = await MainActor.run { (MCPManager.shared.promptLine(), MCPManager.shared.activeTools) }
        system += "\n" + mcpLine
        var input: [[String: Any]] = [["role": "system", "content": system]]
        for message in history.suffix(24) {
            if message.role == .tool, let tool = message.tool {
                // Replay earlier tool use as real function_call / function_call_output items. Plain
                // "[tool] input" assistant text taught the model to type fake tool calls instead of calling.
                let callID = "hist-" + String(tool.id.suffix(40))
                input.append(["type": "function_call", "call_id": callID, "name": tool.name, "arguments": historyArguments(tool)])
                input.append(["type": "function_call_output", "call_id": callID, "output": String(tool.output.prefix(4000))])
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
            // Image generation is never offered on an ordinary chat turn; only when the user explicitly asks.
            if name == "generate_image", !explicitlyAsksForImage(history.last(where: { $0.role == .user })?.content ?? "") { continue }
            tools.append(["type": "function", "name": name, "description": function["description"] ?? "", "parameters": function["parameters"] ?? [:]])
        }
        // MCP server tools: https://modelcontextprotocol.io/specification/2025-06-18/server/tools
        for tool in mcpTools where mode == .code || tool.readOnly {
            let description = "[MCP \(tool.server)] " + String(tool.description.prefix(900))
            tools.append(["type": "function", "name": tool.fullName, "description": description, "parameters": tool.schema])
        }

        var model = tier.modelID
        var effort = tier.effort
        let heavyRefused = await MainActor.run { heavyToolsRefused }
        if tier == .heavy, heavyRefused {
            model = ReplyTier.expert.modelID
            effort = ReplyTier.expert.effort
            await onEvent(.reasoning(heavyNotice))
        }

        // Identical calls (same name and arguments) in this turn reuse the earlier result.
        var seen: [String: String] = [:]
        let maxToolRounds = 8
        var round = 0
        while round <= maxToolRounds {
            round += 1
            if Task.isCancelled { return }
            if round > maxToolRounds {
                // Out of tool rounds: one more request without tools so the model answers with what it has.
                input.append(["role": "user", "content": tr("已经调用了 \(maxToolRounds) 轮工具。不要再调用工具，直接根据已有结果回答。", "You have used tools for \(maxToolRounds) rounds. Do not call more tools; answer from the results you have.")])
                _ = try? await turn(key: trimmed, model: model, effort: effort, input: input, tools: [], onEvent: onEvent)
                return
            }
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
                round -= 1
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
                let signature = call.name + "\u{1F}" + canonicalArguments(call.arguments)
                let result: String
                if let previous = seen[signature] {
                    result = tr("（与本轮之前的一次调用完全相同，没有重复执行，以下是上次的结果。请直接使用它。）\n", "(Identical to an earlier call this turn; not run again. Here is the previous result; use it.)\n") + previous
                } else {
                    result = await execute(call, root: root, key: trimmed, mode: mode, sandbox: sandbox, approval: approval, onTool: onTool, onGate: onGate)
                    seen[signature] = result
                }
                input.append(["type": "function_call_output", "call_id": call.id, "output": result])
            }
        }
    }

    /// Best-effort arguments JSON for a stored tool card (cards keep the displayed input, not the raw JSON).
    private static func historyArguments(_ tool: ToolTrace) -> String {
        if let data = tool.input.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) is [String: Any] { return tool.input }
        let key = ["bash", "run_tests"].contains(tool.name) ? "command" : (tool.name.hasPrefix("mcp__") ? "input" : "path")
        let data = (try? JSONSerialization.data(withJSONObject: [key: tool.input])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Arguments JSON with sorted keys so key order does not defeat the duplicate check.
    private static func canonicalArguments(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let sorted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: sorted, encoding: .utf8) else { return raw }
        return text
    }

    private static let heavyNotice = tr("Heavy 多智能体模型调用本机工具需要 xAI 的 beta 权限，这一轮改用 Expert · grok-4.7。\n\n", "Heavy multi-agent tool use needs xAI beta access, so this turn uses Expert · grok-4.7.\n\n")

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
        if call.name.hasPrefix("mcp__") {
            return await executeMCP(call, mode: mode, approval: approval, onTool: onTool, onGate: onGate)
        }
        if !allowed(mode, call.name) {
            let output = tr("当前是\(mode == .ask ? "提问" : "计划")模式，不能改文件或执行命令。", "\(mode == .ask ? "Ask" : "Plan") mode can't change files or run commands.")
            await onTool(ToolTrace(id: call.id, name: call.name, input: call.arguments, output: output, status: "error"))
            return output
        }
        if call.name == "ask_user" {
            let question = (jsonObject(call.arguments)["question"] as? String) ?? tr("继续吗？", "Continue?")
            await onTool(ToolTrace(id: call.id, name: call.name, input: question, output: "", status: "ask"))
            let answer = await onGate(tr("需要你回答", "Needs your answer"), question, "ask")
            let output = answer == "no" || answer.isEmpty ? tr("用户没有回答。", "The user didn't answer.") : answer
            await onTool(ToolTrace(id: call.id, name: call.name, input: question, output: output, status: "done"))
            return output
        }
        let shown = displayInput(call)
        if let reason = escalation(name: call.name, arguments: call.arguments, root: root, sandbox: sandbox, approval: approval) {
            await onTool(ToolTrace(id: call.id, name: call.name, input: shown, output: "", status: "approval"))
            let answer = await onGate(reason, shown, "approve")
            if answer != "yes" {
                let output = tr("用户拒绝了这次操作。", "The user denied this action.")
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

    /// MCP tools: 只读 always asks, 默认 asks until the user picks 始终允许 for that server, 完全访问 never asks.
    /// Tools the server marks readOnlyHint run without asking.
    private static func executeMCP(
        _ call: ToolCall,
        mode: AgentMode,
        approval: String,
        onTool: @escaping @MainActor (ToolTrace) -> Void,
        onGate: @escaping @MainActor (String, String, String) async -> String
    ) async -> String {
        guard let tool = await MainActor.run(body: { MCPManager.shared.tool(named: call.name) }) else {
            let output = tr("这个 MCP 工具现在不可用（服务器未连接）。", "This MCP tool is unavailable (server not connected).")
            await onTool(ToolTrace(id: call.id, name: call.name, input: call.arguments, output: output, status: "error"))
            return output
        }
        let shown = "\(tool.server) · \(tool.name) \(call.arguments)"
        if mode != .code, !tool.readOnly {
            let output = tr("当前是\(mode == .ask ? "提问" : "计划")模式，只能用只读的 MCP 工具。", "\(mode == .ask ? "Ask" : "Plan") mode can only use read-only MCP tools.")
            await onTool(ToolTrace(id: call.id, name: call.name, input: shown, output: output, status: "error"))
            return output
        }
        let trusted = await MainActor.run { MCPManager.shared.alwaysAllowed(tool.server) }
        let ask: Bool
        switch approval {
        case "never": ask = false
        case "readOnly": ask = !tool.readOnly
        default: ask = !tool.readOnly && !trusted
        }
        if ask {
            await onTool(ToolTrace(id: call.id, name: call.name, input: shown, output: "", status: "approval"))
            let answer = await onGate(tr("要调用 MCP 工具 \(tool.server) · \(tool.name)。允许？", "Call MCP tool \(tool.server) · \(tool.name)?"), shown, approval == "readOnly" ? "approve" : "approve-mcp:" + tool.server)
            if answer == "always" {
                await MainActor.run { MCPManager.shared.setAlwaysAllow(tool.server, true) }
            } else if answer != "yes" {
                let output = tr("用户拒绝了这次操作。", "The user denied this action.")
                await onTool(ToolTrace(id: call.id, name: call.name, input: shown, output: output, status: "error"))
                return output
            }
        }
        await onTool(ToolTrace(id: call.id, name: call.name, input: shown, output: "", status: "running"))
        let result = await MCPManager.shared.call(tool, arguments: call.arguments)
        await onTool(ToolTrace(id: call.id, name: call.name, input: shown, output: result.text, status: result.ok ? "done" : "error", images: result.images.isEmpty ? nil : result.images))
        return result.ok ? result.text : tr("工具返回错误：", "Tool returned an error: ") + result.text
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
        // Redirecting to /dev/null (2>/dev/null, &>/dev/null) discards output; it never overwrites a file.
        let text = (" " + command.lowercased().replacingOccurrences(of: "\n", with: " ; ") + " ")
            .replacingOccurrences(of: #"[0-9&]?>>?\s*/dev/null"#, with: " ", options: .regularExpression)
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
            // A path the tools cannot resolve (outside the home folder) is still out of scope: ask, then the tool reports why it failed.
            guard let url = try? LocalTools.resolve(root, path) else { return path }
            if url.path != base, !url.path.hasPrefix(base + "/") { return url.path }
        }
        return nil
    }

    /// Reads that need approval even though they are read-only: the home folder root listing,
    /// credential dotfiles/dirs, keychains, key/token/secret-like file names, and anything outside
    /// the working folder. Reads inside the working folder stay automatic.
    static func sensitiveRead(name: String, arguments: String, root: URL) -> String? {
        let args = jsonObject(arguments)
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        var candidates: [String] = []
        var explicitPaths: [String] = []
        switch name {
        case "bash", "run_tests":
            let command = (args["command"] as? String) ?? ""
            let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";|&()<>=\"'`"))
            candidates = command.components(separatedBy: separators).filter { !$0.isEmpty }
        case "read_file", "glob", "grep", "codebase_search":
            for key in ["path", "file", "directory", "dir", "pattern", "glob"] {
                if let value = args[key] as? String, !value.isEmpty { candidates.append(value); explicitPaths.append(value) }
            }
        default:
            return nil
        }
        let systemPrefixes = ["/usr/", "/bin/", "/sbin/", "/opt/homebrew/", "/dev/null", "/dev/std", "/System/", "/Applications/Xcode.app/", "/Library/Developer/"]
        for raw in candidates {
            var token = raw
            for prefix in ["$HOME", "${HOME}"] where token.hasPrefix(prefix) { token = home + token.dropFirst(prefix.count) }
            if token == "~" || token.hasPrefix("~/") { token = home + token.dropFirst(1) }
            let lower = token.lowercased()
            let trimmed = token.hasSuffix("/") && token.count > 1 ? String(token.dropLast()) : token
            if trimmed == home || trimmed == "/Users" || trimmed == "/" { return raw }
            let leaf = (lower as NSString).lastPathComponent
            let components = lower.split(separator: "/").map(String.init)
            let dotDirs: Set<String> = [".ssh", ".gnupg", ".aws", ".config", ".secrets", ".netrc", ".kube", ".docker"]
            if components.contains(where: { dotDirs.contains($0) || $0.hasPrefix(".env") }) { return raw }
            if lower.contains("keychains") || lower.contains("keychain-db") { return raw }
            let looksLikePath = token.contains("/") || token.contains(".") || explicitPaths.contains(raw)
            if looksLikePath {
                let patterns = [#"key"#, #"\.pem$"#, #"^id_"#, #"token"#, #"secret"#, #"credential"#]
                if patterns.contains(where: { leaf.range(of: $0, options: .regularExpression) != nil }), !leaf.hasSuffix(".swift") {
                    return raw
                }
            }
            if token.hasPrefix("/") {
                if systemPrefixes.contains(where: { token.hasPrefix($0) }) || token == "/tmp" || token.hasPrefix("/tmp/") || token.hasPrefix("/private/tmp/") { continue }
                let path = URL(fileURLWithPath: token).standardizedFileURL.path
                if path != base, !path.hasPrefix(base + "/") { return raw }
            } else if explicitPaths.contains(raw), raw.hasPrefix("..") {
                let path = root.appendingPathComponent(raw).standardizedFileURL.path
                if path != base, !path.hasPrefix(base + "/") { return raw }
            }
        }
        return nil
    }

    private static func escalation(name: String, arguments: String, root: URL, sandbox: String, approval: String) -> String? {
        let command = (jsonObject(arguments)["command"] as? String) ?? ""
        let writes = mutating.contains(name) || name == "todo_write" || name == "undo"
        if sandbox == "read-only", writes {
            return approval == "never" ? nil : tr("只读沙箱。允许这一次写出或执行？", "Read-only sandbox. Allow this write or run once?")
        }
        if approval == "readOnly", writes, !((name == "bash") && isSafeReadOnlyCommand(command)) {
            return name == "bash" ? tr("只读模式。允许运行这条命令？", "Read-only mode. Allow this command?") : tr("只读模式。允许这次修改？", "Read-only mode. Allow this change?")
        }
        if approval != "never", (name == "bash" || name == "run_tests" || name == "open_pr"), isDestructive(command) {
            return tr("这条命令可能删除或覆盖文件。允许执行？", "This command may delete or overwrite files. Run it?")
        }
        if approval != "never", ["write_file", "edit_file", "apply_patch"].contains(name), let outside = outsidePath(arguments, root: root) {
            return tr("要改工程以外的文件：\(outside)。允许？", "Change files outside the project: \(outside)?")
        }
        if approval != "never", let what = sensitiveRead(name: name, arguments: arguments, root: root) {
            return tr("要读取敏感位置：\(what)。允许这一次？", "Read a sensitive location: \(what). Allow once?")
        }
        if networked.contains(name) || ((name == "bash" || name == "run_tests") && needsNetwork(command)) {
            return approval == "never" ? nil : tr("需要联网。允许这一次？", "Needs network access. Allow once?")
        }
        if sandbox == "full-access" && (name == "bash" || name == "run_tests") && approval != "never" {
            return tr("完全访问。允许这条命令？", "Full access. Allow this command?")
        }
        return nil
    }

    /// Commands that only read: every segment of a pipeline or && / ; chain starts with a known
    /// read-only program, and there is no redirection or command substitution.
    static func isSafeReadOnlyCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        for bad in [">", "`", "$(", "<(", "\n"] where trimmed.contains(bad) { return false }
        let safe: Set<String> = ["ls", "cat", "head", "tail", "wc", "pwd", "echo", "grep", "rg", "find", "file", "stat", "du", "df", "which", "whoami", "date", "uname", "tree", "less", "sort", "uniq", "cut", "diff", "basename", "dirname", "realpath", "env", "printenv", "sw_vers", "mdls", "md5", "shasum"]
        let gitSafe: Set<String> = ["status", "log", "diff", "show", "branch", "remote", "rev-parse", "ls-files", "blame", "tag"]
        let segments = trimmed.components(separatedBy: CharacterSet(charactersIn: "|;&")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for segment in segments {
            let words = segment.split(separator: " ").map(String.init)
            guard let first = words.first else { continue }
            if first == "git" {
                guard words.count > 1, gitSafe.contains(words[1]) else { return false }
            } else if first == "find" {
                if words.contains(where: { ["-delete", "-exec", "-execdir", "-ok"].contains($0) }) { return false }
            } else if !safe.contains(first) {
                return false
            }
        }
        return true
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
        tool("read_file", "Read a text file on the user's Mac. Relative paths are inside the working folder; ~/ and absolute paths are allowed. offset and limit are 1-based line numbers.", ["path"], extra: ["offset": "number", "limit": "number"]),
        tool("write_file", "Create or replace a text file on the user's Mac. Relative paths are inside the working folder; ~/ and absolute paths are allowed.", ["path", "content"]),
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
        let fresh = await TokenStore.valid()
        let trimmed = (fresh.isEmpty ? key : fresh).trimmingCharacters(in: .whitespacesAndNewlines)
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
        throw GrokClientError.badStatus(-1, tr("没有生成图片。", "No image was generated."))
    }

    /// Async video generation: POST /v1/videos/generations then poll GET /v1/videos/{request_id}.
    /// https://docs.x.ai/developers/rest-api-reference/inference/videos
    static func imagineVideo(key: String, prompt: String, onProgress: @escaping @MainActor (Int) -> Void) async throws -> URL {
        let fresh = await TokenStore.valid()
        let trimmed = (fresh.isEmpty ? key : fresh).trimmingCharacters(in: .whitespacesAndNewlines)
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
                    throw GrokClientError.badStatus(-1, tr("视频没有通过内容审核。", "The video didn't pass moderation."))
                }
                guard let raw = video?["url"] as? String, let url = URL(string: raw) else {
                    throw GrokClientError.badStatus(-1, tr("没有拿到视频地址。", "No video URL was returned."))
                }
                return url
            case "failed", "expired":
                let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? ""
                throw GrokClientError.badStatus(-1, message.isEmpty ? tr("视频生成失败。", "Video generation failed.") : tr("视频生成失败。\(message.prefix(160))", "Video generation failed. \(message.prefix(160))"))
            default:
                if let progress = json["progress"] as? Int {
                    await MainActor.run { onProgress(progress) }
                }
                if status >= 400 { throw GrokClientError.badStatus(status, friendly(status, data)) }
            }
        }
        throw GrokClientError.badStatus(-1, tr("视频生成超时。", "Video generation timed out."))
    }
}

/// True only for a clear, explicit request to create an image (e.g. "画一张…", "generate an image").
/// Video is never generated from chat; it requires Imagine → 视频.
func explicitlyAsksForImage(_ text: String) -> Bool {
    let lower = text.lowercased()
    let cues = ["生成图片", "生成一张", "生成一幅", "画一张", "画一幅", "画一个", "帮我画", "给我画", "做一张图", "出一张图",
                "generate an image", "generate a picture", "create an image", "create a picture", "draw a picture", "draw me", "make an image"]
    return cues.contains { lower.contains($0) }
}

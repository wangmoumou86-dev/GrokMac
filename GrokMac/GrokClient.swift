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
}

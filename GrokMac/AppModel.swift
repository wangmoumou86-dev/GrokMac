import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var sessions: [ChatSession]
    var activeID: UUID
    var tier: ReplyTier
    var mode: AgentMode
    var cliOpen: Bool
    var place: AppPlace = .chat
    var hubTab = "connectors"
    var botsOpen = true
    var connected: [String] = ["github"]
    var bots: [GrokBot] = []
    var skills: [GrokSkill] = GrokCatalog.defaultSkills
    var automations: [GrokAutomation] = []
    var activeBotID: UUID?
    var busy = false
    var showPalette = false
    var showLogin = true
    var signedIn = !KeychainStore.load().isEmpty
    var loginWaiting = false
    var loginFailed = false
    var projectLabel = ProjectStore.label()
    var autoRun = false
    var allowNetwork = true
    var sandboxMode = "workspace-write"
    var approvalPolicy = "on-request"
    var useWorktree = false
    var webSearch = UserDefaults.standard.bool(forKey: "grok.webSearch") {
        didSet { UserDefaults.standard.set(webSearch, forKey: "grok.webSearch") }
    }
    var xSearch = UserDefaults.standard.bool(forKey: "grok.xSearch") {
        didSet { UserDefaults.standard.set(xSearch, forKey: "grok.xSearch") }
    }
    var gateTitle = ""
    var gateDetail = ""
    var gateKind = ""
    private var gateWait: CheckedContinuation<String, Never>?

    private var chatTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init() {
        let stored = Self.load()
        if let stored, !stored.sessions.isEmpty {
            sessions = stored.sessions
            activeID = stored.sessions.contains(where: { $0.id == stored.activeID }) ? stored.activeID : stored.sessions[0].id
            tier = stored.tier
            mode = stored.mode
            cliOpen = stored.cliOpen
        } else {
            let session = ChatSession.fresh()
            sessions = [session]
            activeID = session.id
            tier = .fast
            mode = .code
            cliOpen = true
        }
        if let extra = Self.loadExtra() {
            place = extra.place
            hubTab = extra.hubTab
            connected = extra.connected
            bots = extra.bots
            skills = extra.skills.isEmpty ? GrokCatalog.defaultSkills : extra.skills
            automations = extra.automations
            activeBotID = extra.activeBotID
            sandboxMode = extra.sandboxMode ?? "workspace-write"
            approvalPolicy = extra.approvalPolicy ?? "on-request"
            useWorktree = extra.useWorktree ?? false
        }
        showLogin = !signedIn
        if signedIn { clearLoginErrors() }
    }

    /// Every 登录 entry point goes through here so the paste field always shows.
    func beginLogin() {
        showLogin = true
        loginWaiting = true
        loginFailed = false
        LoginSession.start { [weak self] ok in
            self?.loginFinished(ok)
        }
    }

    func submitLoginCode(_ code: String) {
        loginFailed = false
        LoginSession.submit(pasted: code) { [weak self] ok in
            self?.loginFinished(ok)
        }
    }

    func skipLogin() {
        showLogin = false
        loginWaiting = false
        loginFailed = false
    }

    func signOut() {
        KeychainStore.save("")
        signedIn = false
        beginLogin()
    }

    /// Drops old "no key / please log in" error bubbles once a login works.
    private func clearLoginErrors() {
        for index in sessions.indices {
            let before = sessions[index].messages.count
            sessions[index].messages.removeAll { message in
                message.error && (message.content.contains("API Key") || message.content.contains("先登录"))
            }
            if sessions[index].messages.count != before { scheduleSave() }
        }
    }

    private func loginFinished(_ ok: Bool) {
        if ok {
            signedIn = true
            clearLoginErrors()
            skipLogin()
        } else {
            loginFailed = true
        }
    }

    var active: ChatSession {
        sessions.first { $0.id == activeID } ?? sessions[0]
    }

    func newSession() {
        let session = ChatSession.fresh()
        sessions.insert(session, at: 0)
        activeID = session.id
        place = .chat
        scheduleSave()
    }

    func select(_ id: UUID) {
        activeID = id
        place = .chat
        scheduleSave()
    }

    func remove(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        if sessions.isEmpty { newSession(); return }
        if activeID == id { activeID = sessions[0].id }
        scheduleSave()
    }

    func rename(_ title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updateActive { session in
            session.title = String((cleaned.isEmpty ? "新对话" : cleaned).prefix(48))
        }
    }

    func cycleMode() {
        let order = AgentMode.allCases
        let index = order.firstIndex(of: mode) ?? 0
        mode = order[(index + 1) % order.count]
        scheduleSave()
    }

    func copyLast() {
        guard let last = active.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty && !$0.pending }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(last.content, forType: .string)
    }

    func stop() {
        chatTask?.cancel()
        if gateWait != nil { decide("no") }
    }

    func send(_ raw: String, surface: ChatSurface) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        if surface == .cli, text.hasPrefix("/") {
            if case .send(let rest) = interpret(text) {
                deliver(rest, surface: surface)
            }
            return
        }
        deliver(text, surface: surface)
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择工程"
        panel.message = "工具只会读写这个文件夹。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProjectStore.save(url)
            projectLabel = url.path
        } catch {
            projectLabel = "没能记住这个文件夹"
        }
    }

    private func interpret(_ raw: String) -> CommandOutcome {
        let parts = raw.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let cmd = parts.first.map(String.init)?.lowercased() ?? ""
        let arg = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""

        func done(_ text: String) -> CommandOutcome {
            meta(text)
            return .done
        }

        switch cmd {
        case "help":
            return done(commandHelp)
        case "new", "clear", "home":
            newSession()
            return .done
        case "model", "m":
            guard !arg.isEmpty else {
                return done("当前是 \(tier.title) · \(tier.hint)\n可选：auto、fast、expert、heavy")
            }
            guard let next = ReplyTier(rawValue: arg.lowercased()) else {
                return done("用法：/model auto|fast|expert|heavy")
            }
            tier = next
            scheduleSave()
            return done("已切换到 \(next.title) · \(next.hint)")
        case "mode":
            guard !arg.isEmpty else {
                return done("当前模式 \(mode.rawValue)\n可选：code、plan、ask。终端里也可以 Shift+Tab。")
            }
            guard let next = AgentMode(rawValue: arg.lowercased()) else {
                return done("用法：/mode code|plan|ask")
            }
            mode = next
            scheduleSave()
            return done("模式：\(next.rawValue)")
        case "code", "plan", "ask":
            mode = AgentMode(rawValue: cmd) ?? mode
            scheduleSave()
            if arg.isEmpty { return done("模式：\(cmd)") }
            return .send(arg)
        case "context":
            return done("上下文大约 \(contextPercent(active.messages))%（按字符估算，对照 128k tokens）")
        case "sessions":
            let lines = sessions.map { ($0.id == activeID ? "• " : "  ") + $0.title }.joined(separator: "\n")
            return done(lines.isEmpty ? "没有对话" : lines)
        case "rename", "title":
            guard !arg.isEmpty else { return done("用法：/rename 标题") }
            rename(arg)
            return done("已重命名为 \(active.title)")
        case "compact":
            updateActive { session in
                session.messages = Array(session.messages.filter { $0.role != .meta }.suffix(6))
            }
            return done("已压缩较早的消息，只保留最近几轮。")
        case "quit", "exit":
            NSApplication.shared.terminate(nil)
            return .done
        case "project", "folder":
            return done("当前工程\n\(projectLabel)\n在设置（⌘,）里更换。工具只会改这个文件夹。")
        case "undo":
            undoLastChange()
            return .done
        default:
            return done("未知命令 /\(cmd)。输入 /help 查看。")
        }
    }

    private func meta(_ text: String) {
        let message = ChatMessage(role: .meta, content: text, surface: .cli)
        updateActive { session in
            session.messages.append(message)
            session.updatedAt = .now
        }
    }

    private func deliver(_ text: String, surface: ChatSurface) {
        let sessionID = activeID
        let user = ChatMessage(role: .user, content: text, surface: surface)
        let assistantID = UUID()
        let assistant = ChatMessage(id: assistantID, role: .assistant, content: "", surface: surface, pending: true)
        let history = active.messages + [user]
        updateActive { session in
            if session.title == "新对话" {
                session.title = String(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(36))
            }
            session.updatedAt = .now
            session.messages.append(contentsOf: [user, assistant])
        }
        busy = true
        let chosenTier = tier.resolved(prompt: text, mode: mode)
        let chosenMode = mode
        let key = KeychainStore.load()
        let imagine = place == .imagine && surface == .web
        let note = contextNote()
        let search = (webSearch ? ["web_search"] : []) + (xSearch ? ["x_search"] : [])
        chatTask?.cancel()
        chatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if imagine {
                await self.runImagine(sessionID: sessionID, messageID: assistantID, prompt: text, key: key)
                return
            }
            if surface == .cli || ProjectStore.url() != nil {
                await self.runTools(sessionID: sessionID, messageID: assistantID, history: history, key: key, note: note)
                return
            }
            var acc = ""
            do {
                try await GrokClient.stream(
                    key: key,
                    history: history,
                    tier: chosenTier,
                    mode: chosenMode,
                    surface: surface,
                    note: note,
                    search: search
                ) { event in
                    switch event {
                    case .text(let chunk):
                        acc += chunk
                        self.replaceAssistant(sessionID: sessionID, messageID: assistantID, content: acc, pending: true, error: false)
                    case .citations(let links):
                        self.updateMessage(sessionID: sessionID, messageID: assistantID) { $0.citations = links }
                    case .reasoning:
                        break
                    }
                }
                if Task.isCancelled {
                    self.finish(sessionID: sessionID, messageID: assistantID, content: acc.isEmpty ? "已停止。" : acc, error: false)
                } else if acc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.finish(sessionID: sessionID, messageID: assistantID, content: "没有返回内容。", error: true)
                } else {
                    self.finish(sessionID: sessionID, messageID: assistantID, content: acc, error: false)
                }
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                if cancelled {
                    self.finish(sessionID: sessionID, messageID: assistantID, content: acc.isEmpty ? "已停止。" : acc, error: false)
                } else {
                    let message = (error as? LocalizedError)?.errorDescription ?? "Grok 没有完成回答。"
                    let combined = acc.isEmpty ? message : acc + "\n\n" + message
                    self.finish(sessionID: sessionID, messageID: assistantID, content: combined, error: true)
                }
            }
            self.busy = false
        }
    }

    private func runImagine(sessionID: UUID, messageID: UUID, prompt: String, key: String) async {
        do {
            let url = try await GrokClient.imagine(key: key, prompt: prompt)
            finish(sessionID: sessionID, messageID: messageID, content: "![生成的图片](\(url))", error: false)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "没有生成图片。"
            finish(sessionID: sessionID, messageID: messageID, content: message, error: true)
        }
        busy = false
    }

    private func runTools(sessionID: UUID, messageID: UUID, history: [ChatMessage], key: String, note: String) async {
        guard let access = ProjectAccess.open() else {
            finish(sessionID: sessionID, messageID: messageID, content: "先在设置（⌘,）里选择工程文件夹。终端里的工具只会改那个目录。", error: true)
            busy = false
            return
        }
        defer { access.close() }
        var root = access.root
        if useWorktree {
            guard let made = LocalTools.makeWorktree(root: access.root) else {
                finish(sessionID: sessionID, messageID: messageID, content: "没能建 Git worktree。这个文件夹得是一个 Git 仓库。", error: true)
                busy = false
                return
            }
            root = made
        }
        var acc = ""
        do {
            try await GrokClient.runAgent(
                key: key,
                history: history,
                root: root,
                mode: mode,
                sandbox: sandboxMode,
                approval: approvalPolicy,
                note: note,
                onTool: { trace in
                    self.upsertTool(sessionID: sessionID, before: messageID, trace: trace)
                },
                onGate: { title, detail, kind in
                    await self.waitGate(title: title, detail: detail, kind: kind)
                },
                onDelta: { chunk in
                    acc += chunk
                    self.replaceAssistant(sessionID: sessionID, messageID: messageID, content: acc, pending: true, error: false)
                }
            )
            if Task.isCancelled {
                finish(sessionID: sessionID, messageID: messageID, content: acc.isEmpty ? "已停止。" : acc, error: false)
            } else if acc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finish(sessionID: sessionID, messageID: messageID, content: "做完了。", error: false)
            } else {
                finish(sessionID: sessionID, messageID: messageID, content: acc, error: false)
            }
        } catch {
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if cancelled {
                finish(sessionID: sessionID, messageID: messageID, content: acc.isEmpty ? "已停止。" : acc, error: false)
            } else {
                let message = (error as? LocalizedError)?.errorDescription ?? "Grok 没有完成。"
                finish(sessionID: sessionID, messageID: messageID, content: acc.isEmpty ? message : acc + "\n\n" + message, error: true)
            }
        }
        busy = false
    }

    func decide(_ value: String) {
        gateTitle = ""
        gateDetail = ""
        gateKind = ""
        gateWait?.resume(returning: value)
        gateWait = nil
    }

    func undoLastChange() {
        guard let access = ProjectAccess.open() else { return }
        Task { @MainActor in
            let (output, _) = await LocalTools.run(name: "undo", arguments: "{}", root: access.root, key: "", access: "workspace")
            access.close()
            self.meta(output)
        }
    }

    private func waitGate(title: String, detail: String, kind: String) async -> String {
        gateTitle = title
        gateDetail = String(detail.prefix(1200))
        gateKind = kind
        return await withCheckedContinuation { gateWait = $0 }
    }

    private func upsertTool(sessionID: UUID, before messageID: UUID, trace: ToolTrace) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var session = sessions[index]
        if let existing = session.messages.firstIndex(where: { $0.tool?.id == trace.id }) {
            session.messages[existing].tool = trace
            session.messages[existing].content = trace.output.isEmpty ? trace.input : trace.output
        } else {
            let card = ChatMessage(role: .tool, content: trace.input, surface: .cli, tool: trace)
            if let at = session.messages.firstIndex(where: { $0.id == messageID }) {
                session.messages.insert(card, at: at)
            } else {
                session.messages.append(card)
            }
        }
        session.updatedAt = .now
        sessions[index] = session
    }

    private func finish(sessionID: UUID, messageID: UUID, content: String, error: Bool) {
        replaceAssistant(sessionID: sessionID, messageID: messageID, content: content, pending: false, error: error)
        scheduleSave()
    }

    private func replaceAssistant(sessionID: UUID, messageID: UUID, content: String, pending: Bool, error: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var session = sessions[index]
        guard let messageIndex = session.messages.firstIndex(where: { $0.id == messageID }) else { return }
        session.messages[messageIndex].content = content
        session.messages[messageIndex].pending = pending
        session.messages[messageIndex].error = error
        sessions[index] = session
    }

    private func updateMessage(sessionID: UUID, messageID: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var session = sessions[index]
        guard let messageIndex = session.messages.firstIndex(where: { $0.id == messageID }) else { return }
        change(&session.messages[messageIndex])
        sessions[index] = session
    }

    private func updateActive(_ change: (inout ChatSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == activeID }) else { return }
        var session = sessions[index]
        change(&session)
        sessions[index] = session
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.saveNow()
        }
    }

    private func saveNow() {
        var snapshot = sessions
        for index in snapshot.indices {
            snapshot[index].messages.removeAll { $0.pending && $0.content.isEmpty }
            for messageIndex in snapshot[index].messages.indices {
                snapshot[index].messages[messageIndex].pending = false
            }
        }
        let box = Persisted(sessions: snapshot, activeID: activeID, tier: tier, mode: mode, cliOpen: cliOpen)
        guard let data = try? JSONEncoder().encode(box) else { return }
        do {
            let url = Self.storeURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            let extra = WorkspaceExtra(place: place, hubTab: hubTab, connected: connected, bots: bots, skills: skills, automations: automations, activeBotID: activeBotID, sandboxMode: sandboxMode, approvalPolicy: approvalPolicy, useWorktree: useWorktree)
            if let extraData = try? JSONEncoder().encode(extra) {
                UserDefaults.standard.set(extraData, forKey: "grok.workspace")
            }
        } catch {
            // The next edit retries the write.
        }
    }

    private static func loadExtra() -> WorkspaceExtra? {
        guard let data = UserDefaults.standard.data(forKey: "grok.workspace") else { return nil }
        return try? JSONDecoder().decode(WorkspaceExtra.self, from: data)
    }

    func contextNote() -> String {
        var lines: [String] = []
        if let bot = bots.first(where: { $0.id == activeBotID }) {
            lines.append("Active bot \(bot.name): \(bot.prompt)")
        }
        let onSkills = skills.filter(\.on).map { "\($0.name): \($0.text)" }
        if !onSkills.isEmpty { lines.append(onSkills.joined(separator: "\n")) }
        if !connected.isEmpty { lines.append("Connected: \(connected.joined(separator: ", ")). GitHub can be used with gh. Do not invent mail or files for other accounts.") }
        return lines.joined(separator: "\n")
    }

    func setSandbox(_ value: String) {
        sandboxMode = value
        scheduleSave()
    }

    func setApproval(_ value: String) {
        approvalPolicy = value
        scheduleSave()
    }

    func setWorktree(_ on: Bool) {
        useWorktree = on
        scheduleSave()
    }

    func toggleConnector(_ id: String) {
        if connected.contains(id) { connected.removeAll { $0 == id } } else { connected.append(id) }
        scheduleSave()
    }

    func addBot(name: String, prompt: String) {
        let bot = GrokBot(id: UUID(), name: String((name.isEmpty ? "Bot" : name).prefix(40)), prompt: String(prompt.prefix(2000)))
        bots.append(bot)
        activeBotID = bot.id
        place = .chat
        scheduleSave()
    }

    func addAutomation(name: String, prompt: String, everyHours: Int) {
        automations.append(GrokAutomation(id: UUID(), name: String((name.isEmpty ? "Automation" : name).prefix(40)), prompt: String(prompt.prefix(2000)), everyHours: min(168, max(1, everyHours)), enabled: true, lastRun: .now))
        scheduleSave()
    }

    func dueAutomation() {
        guard !busy, let index = automations.firstIndex(where: { $0.enabled && Date().timeIntervalSince($0.lastRun) >= Double($0.everyHours) * 3600 }) else { return }
        let prompt = automations[index].prompt
        automations[index].lastRun = .now
        place = .chat
        scheduleSave()
        send(prompt, surface: .web)
    }

    private static func load() -> Persisted? {
        guard let data = try? Data(contentsOf: storeURL()) else { return nil }
        return try? JSONDecoder().decode(Persisted.self, from: data)
    }

    private static func storeURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GrokMac", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }
}

private struct Persisted: Codable {
    var sessions: [ChatSession]
    var activeID: UUID
    var tier: ReplyTier
    var mode: AgentMode
    var cliOpen: Bool
}

private struct WorkspaceExtra: Codable {
    var place: AppPlace
    var hubTab: String
    var connected: [String]
    var bots: [GrokBot]
    var skills: [GrokSkill]
    var automations: [GrokAutomation]
    var activeBotID: UUID?
    var sandboxMode: String?
    var approvalPolicy: String?
    var useWorktree: Bool?
}

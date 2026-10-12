import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    /// Declared first so old sandbox data is copied before any other property reads preferences.
    @ObservationIgnored private let migrated: Void = SandboxMigration.run()
    var sessions: [ChatSession]
    var activeID: UUID
    var tier: ReplyTier { didSet { scheduleSave() } }
    var mode: AgentMode { didSet { scheduleSave() } }
    var place: AppPlace = .chat {
        didSet { if place != .imagine { imagineVideo = false } }
    }
    var hubTab = "connectors"
    var botsOpen = true
    var connected: [String] = ["github"]
    // Persist every edit made from the Skills / Bots / Automations pages.
    var bots: [GrokBot] = [] { didSet { scheduleSave() } }
    var skills: [GrokSkill] = GrokCatalog.defaultSkills { didSet { scheduleSave() } }
    var automations: [GrokAutomation] = [] { didSet { scheduleSave() } }
    var activeBotID: UUID? { didSet { scheduleSave() } }
    var busy = false
    var showPalette = false
    var showSettings = false
    var webURL: URL?
    var showLogin = true
    var signedIn = !KeychainStore.load().isEmpty
    var loginWaiting = false
    var profile = AccountProfile.cached()
    var avatar = AccountProfile.cachedImage()
    var loginFailed = false
    var projectLabel = ProjectStore.label()
    var autoRun = false
    var allowNetwork = true
    var sandboxMode = "workspace-write"
    var approvalPolicy = "on-request"
    var useWorktree = false
    /// Video only when the user picks Imagine → 视频; reset whenever Imagine is left.
    var imagineVideo = false
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
        } else {
            let session = ChatSession.fresh()
            sessions = [session]
            activeID = session.id
            tier = .fast
            mode = .code
        }
        if let extra = Self.loadExtra() {
            // Never reopen in Imagine: a stale Imagine/video mode would turn the next prompt into a generation.
            place = extra.place == .imagine ? .chat : extra.place
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
        // The composer search toggles were removed; drop their stored values.
        UserDefaults.standard.removeObject(forKey: "grok.webSearch")
        UserDefaults.standard.removeObject(forKey: "grok.xSearch")
        showLogin = !signedIn
        if signedIn {
            clearLoginErrors()
            refreshProfile()
        }
    }

    /// Reads name/email/picture from auth.x.ai userinfo with the stored token (no re-login).
    func refreshProfile() {
        let token = KeychainStore.load()
        Task { @MainActor [weak self] in
            guard let result = await AccountProfile.refresh(token: token) else { return }
            self?.profile = result.0
            if let image = result.1 { self?.avatar = image }
        }
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
        profile = nil
        avatar = nil
        AccountProfile.clearCache()
        beginLogin()
    }

    /// Drops old "no key / please log in" error bubbles once a login works.
    private func clearLoginErrors() {
        for index in sessions.indices {
            let before = sessions[index].messages.count
            sessions[index].messages.removeAll { message in
                message.error && (message.content.contains("API Key") || message.content.contains("先登录") || message.content.contains("Sign in first"))
            }
            if sessions[index].messages.count != before { scheduleSave() }
        }
    }

    private func loginFinished(_ ok: Bool) {
        if ok {
            signedIn = true
            clearLoginErrors()
            skipLogin()
            refreshProfile()
        } else {
            loginFailed = true
        }
    }

    var active: ChatSession {
        sessions.first { $0.id == activeID } ?? sessions[0]
    }

    func deleteAllConversations() {
        chatTask?.cancel()
        busy = false
        let session = ChatSession.fresh()
        sessions = [session]
        activeID = session.id
        saveNow()
    }

    /// Clears the URL cache, temp downloads and generated videos. Conversations stay.
    func clearCache() -> String {
        URLCache.shared.removeAllCachedResponses()
        let fm = FileManager.default
        var freed: Int64 = 0
        let videos = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GrokMac/Videos", isDirectory: true)
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.grok.mac", isDirectory: true)
        for folder in [videos, caches] {
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
                let url = folder.appendingPathComponent(name)
                freed += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
                try? fm.removeItem(at: url)
            }
        }
        return ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
    }

    func exportConversations() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tr("Grok 对话导出.md", "Grok conversation export.md")
        panel.allowedContentTypes = [.init(filenameExtension: "md")!, .json]
        panel.message = tr("选 .md 导出为 Markdown，选 .json 导出原始数据。", "Use .md for Markdown or .json for raw data.")
        AttachedPanel.present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            self.writeExport(to: url)
        }
    }

    private func writeExport(to url: URL) {
        if url.pathExtension.lowercased() == "json" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(sessions) { try? data.write(to: url, options: .atomic) }
            return
        }
        var out = ""
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        for session in sessions {
            out += "# \(session.title)\n\n_\(stamp.string(from: session.createdAt))_\n\n"
            for message in session.messages where message.role != .meta {
                switch message.role {
                case .user: out += tr("**你**：\(message.content)\n\n", "**You**: \(message.content)\n\n")
                case .assistant: out += "**Grok**：\(message.content)\n\n"
                case .tool:
                    if let tool = message.tool { out += "```\n$ \(tool.input)\n\(tool.output)\n```\n\n" }
                case .meta: break
                }
            }
            out += "---\n\n"
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
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
            session.title = String((cleaned.isEmpty ? tr("新对话", "New chat") : cleaned).prefix(48))
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

    func send(_ raw: String, surface: ChatSurface, attachments: [ComposerAttachment] = []) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, !attachments.isEmpty { text = attachments.contains { $0.kind == .image } ? tr("描述这张图片。", "Describe this image.") : tr("总结这份文档。", "Summarize this document.") }
        guard !text.isEmpty, !busy else { return }
        if !attachments.isEmpty {
            deliver(text, surface: surface, attachments: attachments)
            return
        }
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
        panel.prompt = tr("选择工程", "Choose project")
        panel.message = tr("工具只会读写这个文件夹。", "Tools only read and write this folder.")
        AttachedPanel.present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            self.rememberProject(url)
        }
    }

    private func rememberProject(_ url: URL) {
        do {
            try ProjectStore.save(url)
            projectLabel = url.path
        } catch {
            projectLabel = tr("没能记住这个文件夹", "Couldn't remember this folder")
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
                return done(tr("当前是 \(tier.title) · \(tier.hint)\n可选：auto、fast、expert、heavy", "Current: \(tier.title) · \(tier.hint)\nOptions: auto, fast, expert, heavy"))
            }
            guard let next = ReplyTier(rawValue: arg.lowercased()) else {
                return done(tr("用法：/model auto|fast|expert|heavy", "Usage: /model auto|fast|expert|heavy"))
            }
            tier = next
            scheduleSave()
            return done(tr("已切换到 \(next.title) · \(next.hint)", "Switched to \(next.title) · \(next.hint)"))
        case "mode":
            guard !arg.isEmpty else {
                return done(tr("当前模式 \(mode.rawValue)\n可选：code、plan、ask。", "Current mode \(mode.rawValue)\nOptions: code, plan, ask."))
            }
            guard let next = AgentMode(rawValue: arg.lowercased()) else {
                return done(tr("用法：/mode code|plan|ask", "Usage: /mode code|plan|ask"))
            }
            mode = next
            scheduleSave()
            return done(tr("模式：\(next.rawValue)", "Mode: \(next.rawValue)"))
        case "code", "plan", "ask":
            mode = AgentMode(rawValue: cmd) ?? mode
            scheduleSave()
            if arg.isEmpty { return done(tr("模式：\(cmd)", "Mode: \(cmd)")) }
            return .send(arg)
        case "context":
            return done(tr("上下文大约 \(contextPercent(active.messages))%（按字符估算，对照 128k tokens）", "Context is about \(contextPercent(active.messages))% (estimated from characters against 128k tokens)"))
        case "sessions":
            let lines = sessions.map { ($0.id == activeID ? "• " : "  ") + $0.title }.joined(separator: "\n")
            return done(lines.isEmpty ? tr("没有对话", "No conversations") : lines)
        case "rename", "title":
            guard !arg.isEmpty else { return done(tr("用法：/rename 标题", "Usage: /rename title")) }
            rename(arg)
            return done(tr("已重命名为 \(active.title)", "Renamed to \(active.title)"))
        case "compact":
            updateActive { session in
                session.messages = Array(session.messages.filter { $0.role != .meta }.suffix(6))
            }
            return done(tr("已压缩较早的消息，只保留最近几轮。", "Compacted earlier messages; kept the last few turns."))
        case "quit", "exit":
            NSApplication.shared.terminate(nil)
            return .done
        case "project", "folder":
            return done(tr("当前工程\n\(projectLabel)\n在设置（⌘,）里更换。工具只会改这个文件夹。", "Current project\n\(projectLabel)\nChange it in Settings (⌘,). Tools only modify this folder."))
        case "undo":
            undoLastChange()
            return .done
        default:
            return done(tr("未知命令 /\(cmd)。输入 /help 查看。", "Unknown command /\(cmd). Type /help."))
        }
    }

    private func meta(_ text: String) {
        let message = ChatMessage(role: .meta, content: text, surface: .cli)
        updateActive { session in
            session.messages.append(message)
            session.updatedAt = .now
        }
    }

    private func deliver(_ text: String, surface: ChatSurface, attachments: [ComposerAttachment] = []) {
        let sessionID = activeID
        var user = ChatMessage(role: .user, content: text, surface: surface)
        if !attachments.isEmpty {
            let images = attachments.compactMap(\.dataURL)
            let pdfs = attachments.filter { $0.kind == .pdf }
            user.images = images.isEmpty ? nil : images
            user.files = attachments.map(\.name)
            if !pdfs.isEmpty {
                user.context = pdfs.map { "[附件 PDF：\($0.name)，以下是提取的文字]\n\($0.text ?? "")" }.joined(separator: "\n\n")
            }
        }
        let assistantID = UUID()
        let assistant = ChatMessage(id: assistantID, role: .assistant, content: "", surface: surface, pending: true)
        let history = active.messages + [user]
        updateActive { session in
            if session.title == "新对话" || session.title == "New chat" {
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
        if place != .imagine { imagineVideo = false }
        let note = contextNote()
        // Web and X search are always on for chat.
        let search = ["web_search", "x_search"]
        chatTask?.cancel()
        chatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if imagine, self.imagineVideo {
                await self.runVideo(sessionID: sessionID, messageID: assistantID, prompt: text, key: key)
                return
            }
            if imagine {
                await self.runImagine(sessionID: sessionID, messageID: assistantID, prompt: text, key: key)
                return
            }
            await self.runTools(sessionID: sessionID, messageID: assistantID, history: history, key: key, note: note, tier: chosenTier, mode: chosenMode, search: search)
        }
    }

    private func runImagine(sessionID: UUID, messageID: UUID, prompt: String, key: String) async {
        do {
            let url = try await GrokClient.imagine(key: key, prompt: prompt)
            finish(sessionID: sessionID, messageID: messageID, content: tr("![生成的图片](\(url))", "![Generated image](\(url))"), error: false)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? tr("没有生成图片。", "No image was generated.")
            finish(sessionID: sessionID, messageID: messageID, content: message, error: true)
        }
        busy = false
    }

    private func runVideo(sessionID: UUID, messageID: UUID, prompt: String, key: String) async {
        replaceAssistant(sessionID: sessionID, messageID: messageID, content: tr("正在生成视频…", "Generating video…"), pending: true, error: false)
        do {
            let remote = try await GrokClient.imagineVideo(key: key, prompt: prompt) { progress in
                self.replaceAssistant(sessionID: sessionID, messageID: messageID, content: tr("正在生成视频… \(progress)%", "Generating video… \(progress)%"), pending: true, error: false)
            }
            replaceAssistant(sessionID: sessionID, messageID: messageID, content: tr("正在下载视频…", "Downloading video…"), pending: true, error: false)
            // The returned URL is temporary, so keep a local copy.
            let (temp, _) = try await URLSession.shared.download(from: remote)
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GrokMac/Videos", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let local = folder.appendingPathComponent("\(messageID.uuidString).mp4")
            try? FileManager.default.removeItem(at: local)
            try FileManager.default.moveItem(at: temp, to: local)
            updateMessage(sessionID: sessionID, messageID: messageID) { $0.video = local.path }
            finish(sessionID: sessionID, messageID: messageID, content: tr("生成的视频", "Generated video"), error: false)
        } catch {
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            let message = cancelled ? tr("已停止。", "Stopped.") : ((error as? LocalizedError)?.errorDescription ?? tr("没有生成视频。", "No video was generated."))
            finish(sessionID: sessionID, messageID: messageID, content: message, error: !cancelled)
        }
        busy = false
    }

    /// Working folder for chat tools: the selected project, or the app's sandbox home when none is chosen.
    private func runTools(sessionID: UUID, messageID: UUID, history: [ChatMessage], key: String, note: String, tier: ReplyTier, mode: AgentMode, search: [String]) async {
        let access = ProjectAccess.open()
        defer { access?.close() }
        var root = access?.root ?? FileManager.default.homeDirectoryForCurrentUser
        if let access, useWorktree {
            guard let made = LocalTools.makeWorktree(root: access.root, session: sessionID) else {
                finish(sessionID: sessionID, messageID: messageID, content: tr("没能建 Git worktree。这个文件夹得是一个 Git 仓库。", "Couldn't create a Git worktree. This folder must be a Git repository."), error: true)
                busy = false
                return
            }
            root = made
        }
        var acc = ""
        do {
            UsageStore.shared.currentSession = sessionID
            try await GrokClient.runAgent(
                key: key,
                history: history,
                root: root,
                projectChosen: access != nil,
                tier: tier,
                mode: mode,
                sandbox: sandboxMode,
                approval: approvalPolicy,
                note: note,
                search: search,
                onTool: { trace in
                    self.upsertTool(sessionID: sessionID, before: messageID, trace: trace)
                },
                onGate: { title, detail, kind in
                    await self.waitGate(title: title, detail: detail, kind: kind)
                },
                onEvent: { event in
                    switch event {
                    case .text(let chunk):
                        acc += chunk
                        self.replaceAssistant(sessionID: sessionID, messageID: messageID, content: acc, pending: true, error: false)
                    case .citations(let links):
                        // Merge across tool turns of this one reply; other messages are never touched.
                        self.updateMessage(sessionID: sessionID, messageID: messageID) { message in
                            let merged = (message.citations ?? []) + links.filter { !(message.citations ?? []).contains($0) }
                            message.citations = merged
                        }
                    case .reasoning(let chunk):
                        self.updateMessage(sessionID: sessionID, messageID: messageID) { $0.reasoning = ($0.reasoning ?? "") + chunk }
                    }
                }
            )
            if Task.isCancelled {
                finish(sessionID: sessionID, messageID: messageID, content: acc.isEmpty ? tr("已停止。", "Stopped.") : acc, error: false)
            } else if acc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finish(sessionID: sessionID, messageID: messageID, content: tr("做完了。", "Done."), error: false)
            } else {
                finish(sessionID: sessionID, messageID: messageID, content: acc, error: false)
            }
        } catch {
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if cancelled {
                finish(sessionID: sessionID, messageID: messageID, content: acc.isEmpty ? tr("已停止。", "Stopped.") : acc, error: false)
            } else {
                let message = (error as? LocalizedError)?.errorDescription ?? tr("Grok 没有完成回答。", "Grok didn't finish the answer.")
                finish(sessionID: sessionID, messageID: messageID, content: acc.isEmpty ? message : acc + "\n\n" + message, error: true)
            }
        }
        if !gateTitle.isEmpty { decide("no") }
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
        let title = sessions.first(where: { $0.id == sessionID })?.title ?? "Grok"
        Prefs.shared.notifyFinished(title: error ? tr("Grok 没有完成", "Grok didn't finish") : title, body: content)
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

    func saveNow() {
        var snapshot = sessions
        for index in snapshot.indices {
            snapshot[index].messages.removeAll { $0.pending && $0.content.isEmpty }
            for messageIndex in snapshot[index].messages.indices {
                snapshot[index].messages[messageIndex].pending = false
            }
        }
        let box = Persisted(sessions: snapshot, activeID: activeID, tier: tier, mode: mode)
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
        let personal = Prefs.shared.personalNote()
        if !personal.isEmpty { lines.append(personal) }
        if let bot = bots.first(where: { $0.id == activeBotID }) {
            lines.append("Active bot \(bot.name): \(bot.prompt)")
        }
        let onSkills = skills.filter(\.on).map { "\($0.name): \($0.text)" }
        if !onSkills.isEmpty { lines.append(onSkills.joined(separator: "\n")) }
        if connected.contains("github") { lines.append("GitHub is connected: use the gh command through bash. No mail, calendar or drive accounts are connected; do not invent their contents.") }
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
        guard !busy, let item = automations.first(where: { $0.enabled && Date().timeIntervalSince($0.lastRun) >= Double($0.everyHours) * 3600 }) else { return }
        runAutomation(item.id)
    }

    /// Runs one automation now in a fresh conversation, so it never lands in the chat the user is reading.
    func runAutomation(_ id: UUID) {
        guard !busy, let index = automations.firstIndex(where: { $0.id == id }) else { return }
        let prompt = automations[index].prompt
        automations[index].lastRun = .now
        newSession()
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
    /// Old builds stored the terminal pane state here; it is read and ignored.
    var cliOpen: Bool?
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

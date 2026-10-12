import Foundation

enum ReplyTier: String, Codable, CaseIterable, Identifiable {
    case auto, fast, expert, heavy
    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ReplyTier(rawValue: raw) ?? .fast
    }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .fast: "Fast"
        case .expert: "Expert"
        case .heavy: "Heavy"
        }
    }

    var hint: String {
        switch self {
        case .auto: tr("自动选择 Fast 或 Expert", "Picks Fast or Expert")
        case .fast: tr("快速回答", "Quick answers")
        case .expert: tr("深度思考 · Grok 4.7", "Deep thinking · Grok 4.7")
        case .heavy: tr("多专家协作 · Grok 4.7", "Multi-expert · Grok 4.7")
        }
    }

    /// Model ids from https://docs.x.ai/docs/models
    var modelID: String {
        switch self {
        case .heavy: "grok-4.20-multi-agent-0309"
        default: "grok-4.7"
        }
    }

    /// reasoning.effort, see https://docs.x.ai/docs/guides/reasoning
    var effort: String? {
        switch self {
        case .fast: "low"
        case .expert, .auto: "high"
        case .heavy: nil
        }
    }

    var styleHint: String {
        switch self {
        case .fast: "Keep the answer short unless the user asks for depth."
        case .auto: "Match the length to the question."
        case .expert, .heavy: "Be thorough and structured, without filler or repetition."
        }
    }

    /// Auto picks Fast or Expert on the client.
    func resolved(prompt: String, mode: AgentMode) -> ReplyTier {
        guard self == .auto else { return self }
        if mode == .code || mode == .plan { return .expert }
        let lower = prompt.lowercased()
        let cues = ["```", "证明", "推导", "分析", "比较", "设计", "架构", "步骤", "为什么", "代码", "算法", "debug", "prove", "analy", "step by step", "explain why", "compare"]
        if prompt.count > 280 || prompt.split(separator: "\n").count > 4 || cues.contains(where: { lower.contains($0) }) {
            return .expert
        }
        return .fast
    }
}

enum AgentMode: String, Codable, CaseIterable, Identifiable {
    case code, plan, ask
    var id: String { rawValue }

    var title: String {
        switch self {
        case .code: tr("代码", "Code")
        case .plan: tr("计划", "Plan")
        case .ask: tr("提问", "Ask")
        }
    }
}

enum AppPlace: String, Codable, CaseIterable, Identifiable {
    case chat, imagine, library, automations, hub
    var id: String { rawValue }
    @MainActor var title: String {
        switch self {
        case .chat: tr("聊天", "Chat")
        case .imagine: "Imagine"
        case .library: tr("资料库", "Library")
        case .automations: tr("自动化", "Automations")
        case .hub: tr("连接器", "Connectors")
        }
    }
}

struct GrokBot: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var prompt: String
}

struct GrokSkill: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var text: String
    var on: Bool
}

struct GrokAutomation: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var prompt: String
    var everyHours: Int
    var enabled: Bool
    var lastRun: Date
}

struct GrokConnector: Identifiable {
    var id: String
    var name: String
    var blurb: String
    var group: String
    var mark: String
}

enum GrokCatalog {
    static let connectors: [GrokConnector] = [
        .init(id: "github", name: "GitHub", blurb: "Search repos and PRs", group: "connected", mark: "gh"),
        .init(id: "finance", name: "Finance", blurb: "Securely connect financial accounts", group: "featured", mark: "Fn"),
        .init(id: "gmail", name: "Gmail", blurb: "Search and draft emails", group: "featured", mark: "M"),
        .init(id: "gcal", name: "Google Calendar", blurb: "Check your schedule", group: "featured", mark: "31"),
        .init(id: "gdrive", name: "Google Drive", blurb: "Search files and docs", group: "featured", mark: "Dr"),
        .init(id: "box", name: "Box", blurb: "Search files and docs", group: "featured", mark: "box"),
        .init(id: "canva", name: "Canva", blurb: "Create and edit designs", group: "featured", mark: "C"),
        .init(id: "notion", name: "Notion", blurb: "Search pages and docs", group: "featured", mark: "N"),
        .init(id: "shopify", name: "Shopify", blurb: "Manage your store", group: "featured", mark: "S"),
        .init(id: "stripe", name: "Stripe", blurb: "Look up payments", group: "featured", mark: "St"),
        .init(id: "vercel", name: "Vercel", blurb: "Manage your deploys", group: "featured", mark: "▲"),
        .init(id: "wix", name: "Wix", blurb: "Manage your Wix site", group: "featured", mark: "W"),
        .init(id: "xads", name: "X Ads", blurb: "Manage campaigns", group: "advertising", mark: "X"),
    ]

    static let defaultSkills: [GrokSkill] = [
        .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Code", text: "Prefer concrete code changes and the local tools.", on: true),
        .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Search", text: "Use web_search when the answer needs current facts.", on: true),
        .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Imagine", text: "Use generate_image when the user wants a picture.", on: false),
    ]
}

enum ChatSurface: String, Codable {
    case web, cli
}

enum ChatRole: String, Codable {
    case user, assistant, meta, tool
}

struct ToolTrace: Codable, Equatable, Hashable {
    var id: String
    var name: String
    var input: String
    var output: String
    var status: String
    /// Local file paths of images an MCP tool returned, shown in the tool card.
    var images: [String]? = nil
}

struct ChatMessage: Identifiable, Codable, Equatable {
    var id: UUID
    var role: ChatRole
    var content: String
    var surface: ChatSurface
    var createdAt: Date
    var pending: Bool
    var error: Bool
    var tool: ToolTrace?
    var image: String?
    var citations: [String]?
    var reasoning: String?
    var images: [String]?
    var files: [String]?
    var context: String?
    var video: String?

    init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        surface: ChatSurface,
        createdAt: Date = .now,
        pending: Bool = false,
        error: Bool = false,
        tool: ToolTrace? = nil,
        image: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.surface = surface
        self.createdAt = createdAt
        self.pending = pending
        self.error = error
        self.tool = tool
        self.image = image
    }
}

struct ChatSession: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]

    static func fresh() -> ChatSession {
        let now = Date()
        return ChatSession(id: UUID(), title: tr("新对话", "New chat"), createdAt: now, updatedAt: now, messages: [])
    }
}

enum CommandOutcome {
    case done
    case send(String)
}

let commandHelp = """
命令
/help        查看命令
/new         新对话（/clear、/home 相同）
/model       auto、fast、expert 或 heavy
/mode        code、plan 或 ask
/code        代码模式，后面可直接写任务
/plan        计划模式
/ask         只回答，不展开实现
/context     上下文大概占用
/sessions    列出对话
/rename      重命名，例如 /rename 发布说明
/compact     丢掉较早的消息
/quit        退出应用
/project     当前工程文件夹

快捷键
⌘N           新对话
⌘K           命令面板
⌘,           设置
"""

struct SlashCommand: Identifiable {
    var id: String { name }
    var name: String
    var hint: String
}

let slashCatalog: [SlashCommand] = [
    .init(name: "/help", hint: tr("命令与快捷键", "Commands and shortcuts")),
    .init(name: "/new", hint: tr("新对话", "New chat")),
    .init(name: "/model", hint: "auto · fast · expert · heavy"),
    .init(name: "/mode", hint: "code · plan · ask"),
    .init(name: "/plan", hint: tr("计划模式", "Plan mode")),
    .init(name: "/ask", hint: tr("只回答", "Answer only")),
    .init(name: "/code", hint: tr("代码模式", "Code mode")),
    .init(name: "/context", hint: tr("上下文占用", "Context usage")),
    .init(name: "/sessions", hint: tr("列出对话", "List conversations")),
    .init(name: "/rename", hint: tr("重命名当前对话", "Rename this conversation")),
    .init(name: "/compact", hint: tr("压缩较早消息", "Compact earlier messages")),
    .init(name: "/quit", hint: tr("退出应用", "Quit the app")),
    .init(name: "/project", hint: tr("当前工程文件夹", "Current project folder")),
]

func slashSuggestions(_ input: String) -> [SlashCommand] {
    guard input.hasPrefix("/") else { return [] }
    let head = input.dropFirst().split(separator: " ").first.map(String.init)?.lowercased() ?? ""
    return slashCatalog.filter { $0.name.dropFirst().lowercased().hasPrefix(head) }
}

func contextPercent(_ messages: [ChatMessage]) -> Int {
    let chars = messages.reduce(0) { $0 + $1.content.count }
    let tokens = Int((Double(chars) / 4).rounded(.up))
    return min(100, Int((Double(tokens) / 1280).rounded()))
}

import Foundation

enum ReplyTier: String, Codable, CaseIterable, Identifiable {
    case fast, auto, expert
    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: "Fast"
        case .auto: "Auto"
        case .expert: "Expert"
        }
    }

    var hint: String {
        switch self {
        case .fast: "更短"
        case .auto: "默认"
        case .expert: "更完整"
        }
    }

    var maxTokens: Int {
        switch self {
        case .fast: 480
        case .auto: 900
        case .expert: 1400
        }
    }

    var temperature: Double {
        switch self {
        case .fast: 0.5
        case .auto: 0.7
        case .expert: 0.4
        }
    }

    var styleHint: String {
        switch self {
        case .fast: "Keep the answer short unless the user asks for depth."
        case .auto: "Match the length to the question."
        case .expert: "Be thorough and structured, without filler or repetition."
        }
    }
}

enum AgentMode: String, Codable, CaseIterable, Identifiable {
    case code, plan, ask
    var id: String { rawValue }

    var title: String {
        switch self {
        case .code: "代码"
        case .plan: "计划"
        case .ask: "提问"
        }
    }
}

enum AppPlace: String, Codable, CaseIterable, Identifiable {
    case chat, imagine, library, automations, hub
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chat: "Chat"
        case .imagine: "Imagine"
        case .library: "Library"
        case .automations: "Automations"
        case .hub: "Connectors"
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
        return ChatSession(id: UUID(), title: "新对话", createdAt: now, updatedAt: now, messages: [])
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
/model       fast、auto 或 expert
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
⌘J           终端
⌘K           命令面板
⌘,           填写 API Key
Shift+Tab    在终端里切换模式
"""

struct SlashCommand: Identifiable {
    var id: String { name }
    var name: String
    var hint: String
}

let slashCatalog: [SlashCommand] = [
    .init(name: "/help", hint: "命令与快捷键"),
    .init(name: "/new", hint: "新对话"),
    .init(name: "/model", hint: "fast · auto · expert"),
    .init(name: "/mode", hint: "code · plan · ask"),
    .init(name: "/plan", hint: "计划模式"),
    .init(name: "/ask", hint: "只回答"),
    .init(name: "/code", hint: "代码模式"),
    .init(name: "/context", hint: "上下文占用"),
    .init(name: "/sessions", hint: "列出对话"),
    .init(name: "/rename", hint: "重命名当前对话"),
    .init(name: "/compact", hint: "压缩较早消息"),
    .init(name: "/quit", hint: "退出应用"),
    .init(name: "/project", hint: "当前工程文件夹"),
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

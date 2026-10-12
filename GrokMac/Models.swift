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

enum ChatSurface: String, Codable {
    case web, cli
}

enum ChatRole: String, Codable {
    case user, assistant, meta
}

struct ChatMessage: Identifiable, Codable, Equatable {
    var id: UUID
    var role: ChatRole
    var content: String
    var surface: ChatSurface
    var createdAt: Date
    var pending: Bool
    var error: Bool

    init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        surface: ChatSurface,
        createdAt: Date = .now,
        pending: Bool = false,
        error: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.surface = surface
        self.createdAt = createdAt
        self.pending = pending
        self.error = error
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

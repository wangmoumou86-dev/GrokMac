import SwiftUI

struct CLIPane: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var cursor = -1
    @FocusState private var focused: Bool

    private var matches: [SlashCommand] { slashSuggestions(draft) }
    private var history: [ChatMessage] {
        model.active.messages.filter { $0.role == .user && $0.surface == .cli }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Grok Build")
                    .font(.caption.monospaced())
                Spacer()
                Text("已连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    if model.active.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Grok Build")
                            Text("会改你选中的工程")
                                .foregroundStyle(.secondary)
                            Text("bash · 读写文件 · grep · 搜索 · 打开链接")
                                .padding(.top, 8)
                                .foregroundStyle(.secondary)
                            Text("先在设置里选择文件夹")
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(model.active.messages) { message in
                                CLILine(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(12)
                    }
                }
                .onChange(of: model.active.messages.last?.content) { _, _ in
                    if let id = model.active.messages.last?.id {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if !matches.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(matches) { item in
                            Button {
                                draft = item.name + " "
                                focused = true
                            } label: {
                                HStack {
                                    Text(item.name)
                                    Spacer()
                                    Text(item.hint)
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption.monospaced())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
                TextField("给终端一个任务，或输入 /", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .focused($focused)
                    .onSubmit { submit() }
                    .onKeyPress(phases: [.down, .repeat]) { press in
                        if press.key == .tab, press.modifiers.contains(.shift) {
                            model.cycleMode()
                            return .handled
                        }
                        if press.key == .upArrow, draft.isEmpty || cursor >= 0 {
                            let next = min(history.count - 1, cursor + 1)
                            guard history.indices.contains(history.count - 1 - next) else { return .ignored }
                            cursor = next
                            draft = history[history.count - 1 - next].content
                            return .handled
                        }
                        return .ignored
                    }
                HStack {
                    Text(model.mode.rawValue)
                    Spacer()
                    Text("\(model.tier.rawValue) · grok-4.5")
                        .lineLimit(1)
                    Spacer()
                    Text("ctx \(contextPercent(model.active.messages))%")
                        .monospacedDigit()
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if model.busy {
            model.stop()
            return
        }
        draft = ""
        cursor = -1
        model.send(text, surface: .cli)
    }
}

private struct CLILine: View {
    var message: ChatMessage

    var body: some View {
        switch message.role {
        case .meta:
            Text(message.content)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .user:
            Text((message.surface == .cli ? "› " : "web › ") + message.content)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .assistant:
            if message.pending, message.content.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                MarkdownView(text: message.content)
                    .foregroundStyle(message.error ? Color(red: 0.88, green: 0.36, blue: 0.39) : Color.primary)
            }
        case .tool:
            if let tool = message.tool {
                ToolCardView(tool: tool)
            }
        }
    }
}

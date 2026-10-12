import SwiftUI
import UniformTypeIdentifiers

struct ChatPane: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var importing = false

    private var visible: [ChatMessage] {
        model.active.messages.filter { $0.role != .meta }
    }

    var body: some View {
        Group {
            if visible.isEmpty {
                VStack(spacing: 20) {
                    Text(model.place == .imagine ? "Imagine" : "Grok")
                        .font(.system(size: 40, weight: .medium))
                    Text(model.place == .imagine ? "描述你要的图片" : "左边是网页端，右边终端改这台 Mac 上的工程")
                        .foregroundStyle(.secondary)
                    composer
                        .frame(maxWidth: 720)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(visible) { message in
                                MessageRow(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: visible.last?.content) { _, _ in
                        if let id = visible.last?.id {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(id, anchor: .bottom)
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    composer
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(model.active.title)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Speaker.shared.speakLast(in: model.active)
                } label: {
                    Image(systemName: "waveform")
                }
                .help("朗读上一条回答")
                Button {
                    model.cliOpen.toggle()
                } label: {
                    Image(systemName: "terminal")
                }
                .help("终端")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .utf8PlainText, .sourceCode, .json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let clip = String(text.prefix(20_000))
            draft = draft.isEmpty ? clip : draft + "\n\n" + clip
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("询问任何问题", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .onSubmit { submit() }
            HStack {
                Menu {
                    Button("插入文本文件") { importing = true }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)

                Menu {
                    ForEach(ReplyTier.allCases) { tier in
                        Button("\(tier.title) · \(tier.hint)") { model.tier = tier }
                    }
                } label: {
                    Text(model.tier.title)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()
                Button {
                    if model.busy { model.stop() } else { submit() }
                } label: {
                    Image(systemName: model.busy ? "stop.fill" : "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(canSend || model.busy ? Color.white : Color.white.opacity(0.12)))
                        .foregroundStyle(canSend || model.busy ? Color.black : Color.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !model.busy)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.12)))
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.busy
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        model.send(text, surface: .web)
    }
}

private struct MessageRow: View {
    var message: ChatMessage

    var body: some View {
        if message.role == .tool, let tool = message.tool {
            ToolCardView(tool: tool)
        } else if message.role == .user {
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .leading, spacing: 4) {
                    if message.surface == .cli {
                        Text("来自终端")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(message.content)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if message.pending, message.content.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    MarkdownView(text: message.content)
                        .foregroundStyle(message.error ? Color(red: 0.88, green: 0.36, blue: 0.39) : Color.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
